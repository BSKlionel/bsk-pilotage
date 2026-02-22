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
