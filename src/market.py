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
