import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='Agent Month', layout='wide')
st.title('Micro â€” Agent x Mois')

p = Path('marts')/'mart_agent_month.parquet'
if not p.exists():
    st.warning('Lance le pipeline.')
else:
    df=pd.read_parquet(p)
    dept = st.multiselect('DÃ©partements', sorted([d for d in df['department'].dropna().unique()])[:200])
    if dept:
        df=df[df['department'].isin(dept)]
    st.dataframe(df, use_container_width=True, height=600)
