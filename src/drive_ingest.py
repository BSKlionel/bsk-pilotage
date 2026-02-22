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
