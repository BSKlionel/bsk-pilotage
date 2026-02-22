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
