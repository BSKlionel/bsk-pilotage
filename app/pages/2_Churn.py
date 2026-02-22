import streamlit as st
import pandas as pd
from pathlib import Path

st.set_page_config(page_title='Churn', layout='wide')
st.title('Churn â€” Top risques')

p = Path('marts')/'mart_churn_pred.parquet'
if not p.exists():
    st.warning('Lance le pipeline.')
else:
    df=pd.read_parquet(p).sort_values('churn_proba', ascending=False)
    st.dataframe(df.head(200), use_container_width=True)
