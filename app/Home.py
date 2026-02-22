import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='BSK Pilotage', layout='wide')

MART = Path('marts')
st.title('BSK Pilotage â€” Dashboard')

col1,col2,col3 = st.columns(3)
if (MART/'mart_funnel.parquet').exists():
    funnel = pd.read_parquet(MART/'mart_funnel.parquet')
    fact = pd.read_parquet(MART/'fact_deal.parquet')
    ca = float(fact['fees_ht'].fillna(0).sum())
    coll.metric("CA HT", f"{ca:,.0f} €".replace(",", " "))
    col2.metric('Compromis', int(fact['compromise_signed_at'].notna().sum()))
    col3.metric('Actes', int(fact['deed_at'].notna().sum()))

    st.subheader('Funnel mensuel')
    st.line_chart(funnel.set_index('ym')[['compromises','deeds']])

    st.subheader('TÃ©lÃ©chargements')
    st.write('Rapport HTML:', str(Path('reports')/'pilotage.html'))
    st.write('Pack Excel:', str(Path('exports')/'pilotage_mart.xlsx'))
else:
    st.warning('Pas de marts dÃ©tectÃ©s. Lance le pipeline: python run_pipeline.py --full')
