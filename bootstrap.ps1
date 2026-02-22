# bootstrap.ps1 — génère toute l'appli (moteur + streamlit) en 1 shot
$ErrorActionPreference = "Stop"

mkdir -Force DataRaw,config,external_cache,warehouse,marts,reports,exports,src,app,app\pages | Out-Null

@"
pandas==2.2.3
numpy==2.1.3
pyarrow==18.0.0
openpyxl==3.1.5
xlsxwriter==3.2.0
PyYAML==6.0.2
requests==2.32.3
beautifulsoup4==4.12.3
lxml==5.3.0
scikit-learn==1.5.2
statsmodels==0.14.4
plotly==5.24.1
jinja2==3.1.4
tqdm==4.67.1
streamlit==1.32.2
google-api-python-client==2.160.0
google-auth==2.36.0
google-auth-httplib2==0.2.0
google-auth-oauthlib==1.2.1
"@ | Set-Content -Encoding UTF8 .\requirements.txt

@"
project:
  name: BSK_Pilotage
  timezone: Europe/Paris

data:
  # Mode local (si tu synchronises Drive sur ton PC)
  local_dataraw_path: ./DataRaw

  # Mode Drive (recommandé pour URL publique Streamlit Cloud)
  drive_enabled: true
  drive_folder_id: "PASTE_DRIVE_FOLDER_ID_HERE"

  # Local only: chemin vers le JSON du service account (sur ton PC)
  service_account_json_path: "./secrets/service_account.json"

market:
  enabled: true
  meilleursreseaux_evolutions_url: "https://meilleursreseaux.com/immobilier/mandataires/evolutions/"
  igedd_longterm_url: "https://www.igedd.developpement-durable.gouv.fr/prix-immobilier-evolution-a-long-terme-a1048.html"
  acpr_credit_habitat_url: "https://acpr.banque-france.fr/fr/publications-et-statistiques/statistiques/suivi-mensuel-de-la-production-de-credits-lhabitat"
  insee_price_series_url: "https://www.insee.fr/fr/statistiques/series/105071770"
  datagouv_ventes_anciens_url: "https://www.data.gouv.fr/datasets/nombre-de-ventes-de-maisons-et-appartements-anciens"

model:
  horizon_months: 36
  churn_observation_months: 6
"@ | Set-Content -Encoding UTF8 .\config\config.yml

@"
fields:
  agent_id: ["agent_id","id_conseiller","conseiller_id","user_id","mandataire_id","id_mandataire"]
  agent_email: ["email","mail","e-mail"]
  agent_sex: ["sexe","gender"]
  agent_age: ["age"]
  agent_department: ["departement","département","dept","department","code_departement","code_dept"]
  agent_joined_at: ["date_entree","joined_at","created_at","date_affiliation","date_inscription"]
  agent_left_at: ["date_sortie","left_at","churned_at","date_resiliation"]

  mandate_id: ["mandat_id","id_mandat","mandate_id"]
  mandate_created_at: ["mandat_created_at","mandate_created_at","date_mandat","date_signature_mandat","created_at_mandat"]
  mandate_type: ["type_mandat","mandate_type","type_de_mandat"]

  compromise_id: ["compromis_id","id_compromis","saleagreement_id","transaction_id"]
  compromise_signed_at: ["signed_at","date_signature","date_compromis","compromis_signed_at"]
  deed_at: ["date_acte","deed_at","attestation_acte_date","acte_authentique_date"]
  fees_ht: ["honoraires_ht","fees_ht","commission_ht","ca_ht","revenue_ht"]
"@ | Set-Content -Encoding UTF8 .\config\semantic_map.yml

@"
import argparse
from pathlib import Path
from src.pipeline import Pipeline

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--ingest", action="store_true")
    ap.add_argument("--market", action="store_true")
    ap.add_argument("--model", action="store_true")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    root = Path('.').resolve()
    pipe = Pipeline(root=root)

    if args.full or args.ingest: pipe.ingest()
    if args.full or args.market: pipe.fetch_market()
    if args.full or args.model: pipe.model()
    if args.full or args.report: pipe.report()

if __name__ == "__main__":
    main()
"@ | Set-Content -Encoding UTF8 .\run_pipeline.py

@"
from dataclasses import dataclass
from pathlib import Path
import yaml

from .io_ingest import Ingestor
from .drive_ingest import DriveIngestor
from .market import MarketFetcher
from .modeling import ModelBuilder
from .reporting import ReportBuilder

@dataclass
class Pipeline:
    root: Path

    def __post_init__(self):
        self.config_dir = self.root / "config"
        self.wh_dir = self.root / "warehouse"
        self.mart_dir = self.root / "marts"
        self.rep_dir = self.root / "reports"
        self.exp_dir = self.root / "exports"
        self.cache_dir = self.root / "external_cache"

        for d in [self.wh_dir, self.mart_dir, self.rep_dir, self.exp_dir, self.cache_dir]:
            d.mkdir(parents=True, exist_ok=True)

        cfg = yaml.safe_load((self.config_dir / "config.yml").read_text(encoding="utf-8"))
        self.cfg = cfg

        self.ingestor = Ingestor(self.root, self.wh_dir, self.config_dir)
        self.drive_ingestor = DriveIngestor(self.root, self.wh_dir, self.config_dir)
        self.market = MarketFetcher(self.cache_dir, cfg)
        self.modeler = ModelBuilder(self.wh_dir, self.mart_dir, self.config_dir, self.cache_dir, cfg)
        self.reporter = ReportBuilder(self.mart_dir, self.rep_dir, self.exp_dir)

    def ingest(self):
        # Drive option (pour URL publique)
        if self.cfg.get("data", {}).get("drive_enabled", False):
            self.drive_ingestor.run()
        # Local option (si tu copies/sync)
        self.ingestor.run()

    def fetch_market(self):
        self.market.run()

    def model(self):
        self.modeler.run()

    def report(self):
        self.reporter.run()
"@ | Set-Content -Encoding UTF8 .\src\pipeline.py

# --------- IO ingest (local DataRaw) ----------
@"
import re, json
from dataclasses import dataclass
from pathlib import Path
import pandas as pd
from tqdm import tqdm

SUPPORTED = {'.csv','.xlsx','.xls','.parquet'}

def _clean_cols(cols):
    def norm(c):
        c = str(c).strip().lower()
        c = re.sub(r'[\\s\\-\\/]+','_',c)
        c = re.sub(r'[^a-z0-9_]+','',c)
        return c
    return [norm(c) for c in cols]

def _read_file(fp: Path):
    if fp.suffix.lower()=='.csv':
        return {fp.stem: pd.read_csv(fp, low_memory=False)}
    if fp.suffix.lower() in ['.xlsx','.xls']:
        xls = pd.ExcelFile(fp)
        out={}
        for sh in xls.sheet_names:
            df = xls.parse(sh)
            key = f\"{fp.stem}__{re.sub(r'\\W+','_',sh).strip('_')}\".lower()
            out[key]=df
        return out
    if fp.suffix.lower()=='.parquet':
        return {fp.stem: pd.read_parquet(fp)}
    raise ValueError(fp)

@dataclass
class Ingestor:
    root: Path
    wh_dir: Path
    config_dir: Path

    def run(self):
        data_dir = (self.root / "DataRaw")
        if not data_dir.exists():
            return
        manifest=[]
        files=[p for p in data_dir.rglob('*') if p.is_file() and p.suffix.lower() in SUPPORTED]
        for fp in tqdm(sorted(files), desc='Ingest(local)'):
            for tname, df in _read_file(fp).items():
                df=df.copy()
                df.columns=_clean_cols(df.columns)
                for c in df.columns:
                    if df[c].dtype=='object':
                        df[c]=df[c].astype(str).str.strip()
                out = self.wh_dir / f\"{tname}.parquet\"
                df.to_parquet(out, index=False)
                manifest.append({'source_file': str(fp), 'table': tname, 'rows': int(df.shape[0]), 'cols': list(df.columns)})
        (self.wh_dir / '_manifest_local.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
"@ | Set-Content -Encoding UTF8 .\src\io_ingest.py

# --------- Drive ingest (service account) ----------
@"
import io, json, re
from dataclasses import dataclass
from pathlib import Path
import pandas as pd
import yaml
from tqdm import tqdm

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

SUPPORTED = {'.csv','.xlsx','.xls','.parquet'}

def _clean_cols(cols):
    def norm(c):
        c = str(c).strip().lower()
        c = re.sub(r'[\\s\\-\\/]+','_',c)
        c = re.sub(r'[^a-z0-9_]+','',c)
        return c
    return [norm(c) for c in cols]

@dataclass
class DriveIngestor:
    root: Path
    wh_dir: Path
    config_dir: Path

    def run(self):
        cfg = yaml.safe_load((self.config_dir / 'config.yml').read_text(encoding='utf-8'))
        dcfg = cfg.get('data', {})
        folder_id = dcfg.get('drive_folder_id')
        if not folder_id or folder_id == 'PASTE_DRIVE_FOLDER_ID_HERE':
            return

        sa_path = dcfg.get('service_account_json_path', './secrets/service_account.json')
        sa_file = (self.root / sa_path)
        if not sa_file.exists():
            # sur Streamlit Cloud, on injecte via secrets; ici on laisse passer
            return

        creds = service_account.Credentials.from_service_account_file(
            str(sa_file),
            scopes=['https://www.googleapis.com/auth/drive.readonly']
        )
        service = build('drive', 'v3', credentials=creds)

        q = f\"'{folder_id}' in parents and trashed=false\"
        res = service.files().list(q=q, fields='files(id,name,mimeType)').execute()
        files = res.get('files', [])

        manifest=[]
        for f in tqdm(files, desc='Ingest(Drive)'):
            name = f['name']
            ext = Path(name).suffix.lower()
            if ext not in SUPPORTED:
                continue

            request = service.files().get_media(fileId=f['id'])
            fh = io.BytesIO()
            downloader = MediaIoBaseDownload(fh, request)
            done=False
            while not done:
                _, done = downloader.next_chunk()

            fh.seek(0)

            # read
            if ext=='.csv':
                df = pd.read_csv(fh, low_memory=False)
                tables = {Path(name).stem: df}
            elif ext in ['.xlsx','.xls']:
                xls = pd.ExcelFile(fh)
                tables={}
                for sh in xls.sheet_names:
                    df = xls.parse(sh)
                    key = f\"{Path(name).stem}__{re.sub(r'\\W+','_',sh).strip('_')}\".lower()
                    tables[key]=df
            elif ext=='.parquet':
                df = pd.read_parquet(fh)
                tables = {Path(name).stem: df}
            else:
                continue

            for tname, df in tables.items():
                df=df.copy()
                df.columns=_clean_cols(df.columns)
                out = self.wh_dir / f\"{tname}.parquet\"
                df.to_parquet(out, index=False)
                manifest.append({'source_file': f\"drive:{name}\", 'table': tname, 'rows': int(df.shape[0]), 'cols': list(df.columns)})

        (self.wh_dir / '_manifest_drive.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
"@ | Set-Content -Encoding UTF8 .\src\drive_ingest.py

# --------- Market fetchers (V0: pages + tables) ----------
@"
from dataclasses import dataclass
from pathlib import Path
from datetime import datetime
import pandas as pd
import requests
from bs4 import BeautifulSoup

UA = {'User-Agent': 'BSK-Pilotage/1.0'}

@dataclass
class MarketFetcher:
    cache_dir: Path
    cfg: dict

    def run(self):
        if not self.cfg.get('market', {}).get('enabled', True):
            return
        self._meilleursreseaux()
        self._igedd_stub()

    def _meilleursreseaux(self):
        url = self.cfg['market']['meilleursreseaux_evolutions_url']
        r = requests.get(url, headers=UA, timeout=30)
        r.raise_for_status()
        soup = BeautifulSoup(r.text, 'lxml')
        table = soup.find('table')
        if not table:
            return
        df = pd.read_html(str(table))[0]
        df['fetched_at'] = datetime.utcnow().isoformat()
        df.to_parquet(self.cache_dir / 'meilleursreseaux_evolutions.parquet', index=False)

    def _igedd_stub(self):
        url = self.cfg['market']['igedd_longterm_url']
        r = requests.get(url, headers=UA, timeout=30)
        r.raise_for_status()
        soup = BeautifulSoup(r.text, 'lxml')
        links = [{'text': a.get_text(strip=True), 'href': a.get('href')} for a in soup.select('a[href]')][:300]
        df = pd.DataFrame(links)
        df['fetched_at'] = datetime.utcnow().isoformat()
        df.to_parquet(self.cache_dir / 'igedd_links.parquet', index=False)
"@ | Set-Content -Encoding UTF8 .\src\market.py

# --------- Modeling + marts (V0) ----------
@"
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
"@ | Set-Content -Encoding UTF8 .\src\modeling.py

# --------- Reporting + exports ----------
@"
from dataclasses import dataclass
from pathlib import Path
from datetime import datetime
import pandas as pd
import plotly.express as px
from jinja2 import Template

TEMPLATE = \"\"\"<html><head><meta charset='utf-8'><title>BSK Pilotage</title></head>
<body style='font-family:Arial;margin:30px'>
<h1>BSK Pilotage – Rapport ({{generated_at}})</h1>
<ul>
<li>CA HT: <b>{{ca_ht}}</b></li>
<li>Compromis: <b>{{compromises}}</b></li>
<li>Actes: <b>{{deeds}}</b></li>
</ul>
<h2>Funnel</h2>{{funnel_plot}}
<h2>Churn (Top 50)</h2>{{churn_plot}}
</body></html>\"\"\"

@dataclass
class ReportBuilder:
    mart_dir: Path
    report_dir: Path
    export_dir: Path

    def run(self):
        fact=pd.read_parquet(self.mart_dir/'fact_deal.parquet')
        funnel=pd.read_parquet(self.mart_dir/'mart_funnel.parquet')
        churn=pd.read_parquet(self.mart_dir/'mart_churn_pred.parquet')

        ca=float(fact['fees_ht'].fillna(0).sum())
        compromises=int(fact['compromise_signed_at'].notna().sum())
        deeds=int(fact['deed_at'].notna().sum())

        fplot=px.line(funnel, x='ym', y=[c for c in ['compromises','deeds','fees_ht'] if c in funnel.columns], markers=True)
        ch=churn.sort_values('churn_proba', ascending=False).head(50)
        chplot=px.bar(ch, x='agent_id', y='churn_proba')

        html=Template(TEMPLATE).render(
            generated_at=datetime.now().isoformat(timespec='seconds'),
            ca_ht=f\"{ca:,.0f} €\".replace(',', ' '),
            compromises=compromises,
            deeds=deeds,
            funnel_plot=fplot.to_html(full_html=False, include_plotlyjs='cdn'),
            churn_plot=chplot.to_html(full_html=False, include_plotlyjs=False),
        )
        (self.report_dir/'pilotage.html').write_text(html, encoding='utf-8')

        xlsx=self.export_dir/'pilotage_mart.xlsx'
        with pd.ExcelWriter(xlsx, engine='xlsxwriter') as w:
            funnel.to_excel(w, sheet_name='funnel', index=False)
            churn.to_excel(w, sheet_name='churn_pred', index=False)
            fact.head(200000).to_excel(w, sheet_name='fact_sample', index=False)
"@ | Set-Content -Encoding UTF8 .\src\reporting.py

# --------- Streamlit app (Home + pages) ----------
@"
import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='BSK Pilotage', layout='wide')

MART = Path('marts')
st.title('BSK Pilotage — Dashboard')

col1,col2,col3 = st.columns(3)
if (MART/'mart_funnel.parquet').exists():
    funnel = pd.read_parquet(MART/'mart_funnel.parquet')
    fact = pd.read_parquet(MART/'fact_deal.parquet')
    ca = float(fact['fees_ht'].fillna(0).sum())
    col1.metric('CA HT', f\"{ca:,.0f} €\".replace(',', ' '))
    col2.metric('Compromis', int(fact['compromise_signed_at'].notna().sum()))
    col3.metric('Actes', int(fact['deed_at'].notna().sum()))

    st.subheader('Funnel mensuel')
    st.line_chart(funnel.set_index('ym')[['compromises','deeds']])

    st.subheader('Téléchargements')
    st.write('Rapport HTML:', str(Path('reports')/'pilotage.html'))
    st.write('Pack Excel:', str(Path('exports')/'pilotage_mart.xlsx'))
else:
    st.warning('Pas de marts détectés. Lance le pipeline: python run_pipeline.py --full')
"@ | Set-Content -Encoding UTF8 .\app\Home.py

@"
import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='Churn', layout='wide')
st.title('Churn — Top risques')

p = Path('marts')/'mart_churn_pred.parquet'
if not p.exists():
    st.warning('Lance le pipeline.')
else:
    df=pd.read_parquet(p).sort_values('churn_proba', ascending=False)
    st.dataframe(df.head(200), use_container_width=True)
"@ | Set-Content -Encoding UTF8 .\app\pages\2_Churn.py

@"
import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='Agent Month', layout='wide')
st.title('Micro — Agent x Mois')

p = Path('marts')/'mart_agent_month.parquet'
if not p.exists():
    st.warning('Lance le pipeline.')
else:
    df=pd.read_parquet(p)
    dept = st.multiselect('Départements', sorted([d for d in df['department'].dropna().unique()])[:200])
    if dept:
        df=df[df['department'].isin(dept)]
    st.dataframe(df, use_container_width=True, height=600)
"@ | Set-Content -Encoding UTF8 .\app\pages\3_Micro.py

@"
@echo off
cd /d %~dp0

python --version >nul 2>&1
IF ERRORLEVEL 1 (
  echo Python n'est pas installe. Installe Python 3.11+ puis relance.
  pause
  exit /b 1
)

python -m pip install -r requirements.txt
python run_pipeline.py --full
python -m streamlit run app/Home.py
"@ | Set-Content -Encoding ASCII .\RUN_LOCAL.bat

Write-Host "OK: projet genere. Etapes suivantes:"
Write-Host "1) Ouvre config/config.yml et colle ton DRIVE_FOLDER_ID."
Write-Host "2) Mets un service_account.json dans ./secrets (local) OU via Streamlit secrets (cloud)."
Write-Host "3) RUN_LOCAL.bat"