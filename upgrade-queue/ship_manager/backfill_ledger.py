#!/usr/bin/env python3
"""Record upgrades that already landed on main without a queue receipt.

    python3 upgrade-queue/ship_manager/backfill_ledger.py           # report only
    python3 upgrade-queue/ship_manager/backfill_ledger.py --write   # update shipments.json

Only edits upgrade-queue/shipments.json; never commits or pushes. Review and commit the
ledger change yourself.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true", help="write the hits into shipments.json")
    args = ap.parse_args()

    found = engine.backfill_landed(write=args.write)
    if not found:
        print("ledger is complete - nothing landed without a receipt")
        return 0
    for uid in engine.topo_order(list(found)):
        print(f"{uid}  ->  {found[uid]['commit'][:10]}")
    verb = "recorded" if args.write else "would record (pass --write)"
    print(f"{len(found)} upgrade(s) {verb}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
