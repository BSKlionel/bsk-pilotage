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
