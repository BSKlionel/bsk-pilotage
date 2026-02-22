from dataclasses import dataclass
from pathlib import Path
from datetime import datetime
import pandas as pd
import plotly.express as px
from jinja2 import Template

TEMPLATE = \"\"\"<html><head><meta charset='utf-8'><title>BSK Pilotage</title></head>
<body style='font-family:Arial;margin:30px'>
<h1>BSK Pilotage â€“ Rapport ({{generated_at}})</h1>
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
            ca_ht=f\"{ca:,.0f} â‚¬\".replace(',', ' '),
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
