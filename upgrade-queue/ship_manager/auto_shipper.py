#!/usr/bin/env python3
"""Auto-shipper - the unattended habit: every day, ship a random 3-7 of the queue's
READY upgrades with zero supervision.

Run by hand:   python3 upgrade-queue/ship_manager/auto_shipper.py [--count N | --dry-run]
Installed as:  ~/Library/LaunchAgents/com.playdock.autoshipper.plist (fires daily at 13:00)

Why this is safe to leave alone:
* It only calls the same engine functions the dashboard's Ship buttons call, so every
  guard applies identically: preflight refuses dirty/staged trees, any failure before
  the commit restores the original bytes, ships land as content + receipt pairs, and
  nothing is ever force-pushed or rewritten.
* It stops at the FIRST failure and never skips ahead - an upgrade that fails its gate
  needs eyes on it, not a queue that ships around it. A failed prepare leaves the tree
  untouched; a failed commit aborts back to the pre-ship bytes.
* It refuses to run when: a manual ship is mid-flight (staged_upgrade set), free disk
  is under MIN_FREE_GB (this machine's builds have died on a full disk before), origin
  is unreachable, or it already ran today (launchd wake-refires stay idempotent).
* A push that fails even after its one retry stops the run and leaves the upgrade in
  the engine's safe COMMITTED state - the next run's reconcile_committed() recovers it,
  so a single pending push can never be overwritten by a later one going missing from
  the ledger.
"""
import argparse
import fcntl
import random
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine

LOG_PATH = engine.SHIP_MANAGER_DIR / "auto_shipper.log"
STATE_PATH = engine.SHIP_MANAGER_DIR / "auto_shipper_state.json"
LOCK_PATH = engine.SHIP_MANAGER_DIR / "auto_shipper.lock"
MIN_FREE_GB = 6          # a full disk has killed builds on this machine before
PUSH_RETRY_PAUSE_S = 60   # one second chance before leaving COMMITTED for next run
PER_SHIP_PAUSE_S = 45     # let watchers settle between ships


def log(msg):
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")
    print(line, flush=True)


def free_gb():
    return shutil.disk_usage(str(engine.REPO_ROOT)).free / 2**30


def remote_reachable():
    return engine.git("ls-remote", "origin", "HEAD", timeout=30)[0] == 0


def today():
    return datetime.now().date().isoformat()


def ready_in_order():
    metas = engine.all_metas()
    return [uid for uid in engine.topo_order()
            if engine.effective_status(uid, metas)[0] == "READY"]


def ship_one(uid):
    """prepare -> commit through the engine. If the commit step itself fails, abort
    back to the pre-ship bytes so the tree is never left with an applied-but-
    uncommitted patch. A push that fails even once after its retry is left in the
    safe COMMITTED state on purpose - that is recoverable, a pile-up is not."""
    r = engine.ship_prepare(uid)
    if not r.get("ok"):
        return {"ok": False, "stage": r.get("stage", "?"), "message": r.get("message", "")}
    r = engine.ship_commit(uid)
    if r.get("ok") and r.get("pushed") is False:
        time.sleep(PUSH_RETRY_PAUSE_S)
        retry = engine.ship_retry_push(uid)
        if retry.get("ok"):
            r = {"ok": True, "pushed": True, "commit": r.get("commit"), "retried": True}
    if not r.get("ok"):
        engine.ship_abort(uid)
    return r


def main():
    ap = argparse.ArgumentParser(description="Unattended queue auto-shipper (3-7/day)")
    ap.add_argument("--count", type=int, default=None,
                    help="ship exactly N upgrades instead of a random 3-7")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would ship today; change nothing")
    ap.add_argument("--force", action="store_true",
                    help="run even if today's run already happened")
    args = ap.parse_args()

    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another auto-shipper instance is running - standing down")
        return 0

    state = engine.load_json(STATE_PATH, {})
    if not args.force and not args.dry_run and state.get("date") == today() and state.get("ran"):
        log("already ran today; nothing to do (use --force to override)")
        return 0

    recovered = engine.reconcile_committed()
    if recovered:
        log(f"recovered pending pushes from a previous run: {', '.join(recovered)}")

    if engine.load_state().get("staged_upgrade"):
        log(f"a manual ship is mid-flight (`{engine.load_state().get('staged_upgrade')}` "
            "is staged) - standing down")
        return 0
    if free_gb() < MIN_FREE_GB:
        log(f"only {free_gb():.1f} GiB free (<{MIN_FREE_GB}) - standing down, nothing shipped")
        return 0
    if not remote_reachable():
        log("origin unreachable - standing down, nothing shipped")
        return 0

    target = args.count if args.count is not None else random.randint(3, 7)

    if args.dry_run:
        ready = ready_in_order()
        log(f"dry run: would ship up to {target} of {len(ready)} READY "
            f"({', '.join(ready[:target])})")
        return 0

    log(f"=== run start: target {target} ship(s) today ===")
    shipped, failed, push_pending = [], None, False
    for i in range(target):
        if free_gb() < MIN_FREE_GB:
            log(f"disk dropped below {MIN_FREE_GB} GiB mid-run - stopping early")
            break
        ready = ready_in_order()
        if not ready:
            log("no READY upgrade left - queue is done (or fully blocked) for today")
            break
        uid = ready[0]
        r = ship_one(uid)
        if not r.get("ok"):
            failed = {"id": uid, "stage": r.get("stage", "?"), "message": r.get("message", "")}
            log(f"FAILED {uid} at {failed['stage']}: {failed['message'][:500]}")
            log("stopping for the day - the failure needs eyes, not a queue that ships around it")
            break
        if r.get("ok") and not r.get("pushed"):
            push_pending = True
            log(f"{uid} committed as {(r.get('commit') or '')[:10]} but push failed even "
                "on retry - left in safe COMMITTED state, stopping for the day")
            break
        shipped.append({"id": uid, "commit": r.get("commit"), "retried": bool(r.get("retried"))})
        log(f"shipped {uid} as {(r.get('commit') or '')[:10]}"
            + (" (pushed after retry)" if r.get("retried") else " (pushed)"))
        if i < target - 1:
            time.sleep(PER_SHIP_PAUSE_S)

    engine.write_json(STATE_PATH, {"date": today(), "ran": True, "target": target,
                                   "shipped": shipped,
                                   "failed": failed, "push_pending": push_pending})
    summary = f"=== run done: {len(shipped)}/{target} shipped"
    if failed:
        summary += f", FAILED at {failed['id']} ({failed['stage']})"
    if push_pending:
        summary += ", one push pending (auto-reconciles next run)"
    log(summary + " ===")
    return 1 if (failed or push_pending) else 0


if __name__ == "__main__":
    sys.exit(main())
