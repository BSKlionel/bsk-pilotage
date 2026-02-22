from dataclasses import dataclass
from pathlib import Path
import numpy as np
import pandas as pd
import yaml
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split

def _load_parquets(d: Path):
    out={}
    for p in d.glob('*.parquet'):
        if p.name.startswith('_'): 
            continue
        out[p.stem]=pd.read_parquet(p)
    return out

def _find_col(df, aliases):
    cols = {str(c).strip().lower(): c for c in df.columns}
    for a in aliases:
        if str(a).strip().lower() in cols:
            return cols[str(a).strip().lower()]
    return None

@dataclass
class ModelBuilder:
    wh_dir: Path
    mart_dir: Path
    config_dir: Path
    cache_dir: Path
    cfg: dict

    def run(self):
        sem = yaml.safe_load((self.config_dir/'semantic_map.yml').read_text(encoding='utf-8'))
        fields = sem.get('fields', {})
        tables = _load_parquets(self.wh_dir)

        agents = self._pick_agents(tables)
        deals  = self._pick_deals(tables)

        dim_agent = self._build_agents(agents, fields)
        fact_deal = self._build_deals(deals, fields)

        dim_agent.to_parquet(self.mart_dir/'dim_agent.parquet', index=False)
        fact_deal.to_parquet(self.mart_dir/'fact_deal.parquet', index=False)

        agent_month = self._agent_month(dim_agent, fact_deal)
        agent_month.to_parquet(self.mart_dir/'mart_agent_month.parquet', index=False)

        funnel = self._funnel(fact_deal)
        funnel.to_parquet(self.mart_dir/'mart_funnel.parquet', index=False)

        churn = self._churn(dim_agent, agent_month)
        churn.to_parquet(self.mart_dir/'mart_churn_pred.parquet', index=False)

    def _pick_agents(self, tables):
        best=None; score=-1
        for _, df in tables.items():
            s=0
            if any(c in df.columns for c in ['email','mail']): s+=3
            if any('depart' in c for c in df.columns): s+=1
            if df.shape[0]>100: s+=1
            if s>score: best=df; score=s
        if best is None: raise RuntimeError('No agents table found')
        return best

    def _pick_deals(self, tables):
        best=None; score=-1
        for _, df in tables.items():
            s=0
            if any('comprom' in c or 'signed' in c or 'date_signature' in c for c in df.columns): s+=3
            if any('honor' in c or 'fees' in c or 'ca' in c for c in df.columns): s+=2
            if df.shape[0]>100: s+=1
            if s>score: best=df; score=s
        if best is None: raise RuntimeError('No deals table found')
        return best

    def _build_agents(self, df, fields):
        df=df.copy()
        idc=_find_col(df, fields.get('agent_id', [])) or df.columns[0]
        out=pd.DataFrame({'agent_id': df[idc].astype(str)})
        ec=_find_col(df, fields.get('agent_email', []))
        dc=_find_col(df, fields.get('agent_department', []))
        jc=_find_col(df, fields.get('agent_joined_at', []))
        lc=_find_col(df, fields.get('agent_left_at', []))
        sc=_find_col(df, fields.get('agent_sex', []))
        ac=_find_col(df, fields.get('agent_age', []))
        if ec: out['email']=df[ec].astype(str).str.lower()
        if dc: out['department']=df[dc].astype(str).str.zfill(2)
        if jc: out['joined_at']=pd.to_datetime(df[jc], errors='coerce')
        if lc: out['left_at']=pd.to_datetime(df[lc], errors='coerce')
        if sc: out['sex']=df[sc].astype(str)
        if ac: out['age']=pd.to_numeric(df[ac], errors='coerce')
        return out.drop_duplicates('agent_id')

    def _build_deals(self, df, fields):
        df=df.copy()
        aid=_find_col(df, fields.get('agent_id', [])) or df.columns[0]
        sc=_find_col(df, fields.get('compromise_signed_at', []))
        dc=_find_col(df, fields.get('deed_at', []))
        fc=_find_col(df, fields.get('fees_ht', []))
        out=pd.DataFrame({'agent_id': df[aid].astype(str)})
        out['compromise_signed_at']=pd.to_datetime(df[sc], errors='coerce') if sc else pd.NaT
        out['deed_at']=pd.to_datetime(df[dc], errors='coerce') if dc else pd.NaT
        out['fees_ht']=pd.to_numeric(df[fc], errors='coerce') if fc else np.nan
        out['ym']=out['compromise_signed_at'].dt.to_period('M').astype(str)
        return out

    def _agent_month(self, dim_agent, fact_deal):
        g = fact_deal.groupby(['agent_id','ym'], as_index=False).agg(
            compromises=('compromise_signed_at','count'),
            deeds=('deed_at', lambda s: s.notna().sum()),
            fees_ht=('fees_ht','sum')
        )
        out = g.merge(dim_agent[['agent_id','joined_at','department','age','sex','left_at']], on='agent_id', how='left')
        out['ym_date']=pd.to_datetime(out['ym']+'-01', errors='coerce')
        out['tenure_months']=((out['ym_date']-out['joined_at'])/np.timedelta64(1,'M')).round(0)
        return out

    def _funnel(self, fact):
        return fact.groupby('ym', as_index=False).agg(
            compromises=('compromise_signed_at','count'),
            deeds=('deed_at', lambda s: s.notna().sum()),
            fees_ht=('fees_ht','sum')
        )

    def _churn(self, dim_agent, agent_month):
        ad=dim_agent.copy()
        ad['churned']=ad['left_at'].notna().astype(int)
        am=agent_month.copy()
        am=am[am['tenure_months'].between(0,6, inclusive='both')]
        feats=am.groupby('agent_id', as_index=False).agg(
            fees_0_6=('fees_ht','sum'),
            compromises_0_6=('compromises','sum'),
            months_obs=('ym','nunique')
        ).fillna(0)
        df=ad.merge(feats, on='agent_id', how='left').fillna(0)
        X=df[['fees_0_6','compromises_0_6','months_obs']].astype(float)
        y=df['churned'].astype(int)
        if len(df)<200 or y.nunique()<2:
            df['churn_proba']=0.0
            return df[['agent_id','churned','churn_proba','fees_0_6','compromises_0_6','months_obs']]
        Xtr,Xte,ytr,yte=train_test_split(X,y,test_size=0.25,random_state=42,stratify=y)
        m=LogisticRegression(max_iter=200)
        m.fit(Xtr,ytr)
        df['churn_proba']=m.predict_proba(X)[:,1]
        return df[['agent_id','churned','churn_proba','fees_0_6','compromises_0_6','months_obs']]
