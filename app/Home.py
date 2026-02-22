import os
import streamlit as st
import pandas as pd
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload
import io

st.set_page_config(page_title="BSK Pilotage", layout="wide")

SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]

def build_flow():
    flow = Flow.from_client_config(
        {
            "web": {
                "client_id": os.environ["OAUTH_CLIENT_ID"],
                "client_secret": os.environ["OAUTH_CLIENT_SECRET"],
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        },
        scopes=SCOPES,
        redirect_uri=os.environ["PUBLIC_BASE_URL"] + "/",
    )
    return flow

def authenticate():
    if "credentials" in st.session_state:
        return st.session_state["credentials"]

    flow = build_flow()
    auth_url, _ = flow.authorization_url(prompt="consent")

    st.markdown("### 🔐 Connexion Google requise")
    st.link_button("Se connecter avec Google", auth_url)
    st.stop()

def download_drive_files(credentials, folder_id):
    service = build("drive", "v3", credentials=credentials)
    results = service.files().list(
        q=f"'{folder_id}' in parents and trashed=false",
        fields="files(id, name)",
    ).execute()

    files = results.get("files", [])
    dataframes = {}

    for file in files:
        if file["name"].endswith(".csv"):
            request = service.files().get_media(fileId=file["id"])
            fh = io.BytesIO()
            downloader = MediaIoBaseDownload(fh, request)
            done = False
            while not done:
                _, done = downloader.next_chunk()

            fh.seek(0)
            df = pd.read_csv(fh)
            dataframes[file["name"]] = df

    return dataframes

st.title("BSK Pilotage Dashboard")

folder_id = os.environ["DRIVE_FOLDER_ID"]

credentials = authenticate()
dfs = download_drive_files(credentials, folder_id)

if not dfs:
    st.warning("Aucun fichier CSV détecté dans Drive.")
    st.stop()

st.success("Données chargées depuis Google Drive ✅")

# Exemple KPI simple
if "compromis_monthly.csv" in dfs:
    df = dfs["compromis_monthly.csv"]
    st.subheader("Compromis Monthly")
    st.dataframe(df.head())

if "fact_user_month_2020_2027.csv" in dfs:
    st.subheader("Users Monthly")
    st.dataframe(dfs["fact_user_month_2020_2027.csv"].head())
