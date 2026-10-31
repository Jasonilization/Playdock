#!/bin/bash
# End-to-end failure-path proof, run entirely inside a CLONE of the real repo so the
# real main tree and the real remote are never at risk:
#   ship a synthetic upgrade -> tests pass -> commit OK -> push FAILS (bogus remote)
#   -> state stays COMMITTED with the commit preserved -> fix remote -> retry push -> SHIPPED
# Also proves: tamper detection between prepare and commit, and dirty-tree refusal.
set -euo pipefail

CLONE=/tmp/shipmgr-e2e/clone
BARE=/tmp/shipmgr-e2e/origin.git
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rm -rf /tmp/shipmgr-e2e
mkdir -p /tmp/shipmgr-e2e
git clone -q "$REAL" "$CLONE" 2>/dev/null || git clone -q "file://$REAL" "$CLONE"
# carry the WORKING queue across (covers any not-yet-committed engine fixes) - replacing
# the cloned copy rather than nesting inside it (cp -a semantics with an existing target)
rm -rf "$CLONE/upgrade-queue"
cp -a "$REAL/upgrade-queue" "$CLONE/upgrade-queue"
git -C "$CLONE" remote set-url origin /nonexistent-bogus-remote.git

cd "$CLONE"
python3 - <<'PYEOF'
import json, pathlib, subprocess, sys
sys.path.insert(0, str(pathlib.Path("upgrade-queue/ship_manager").resolve()))
import engine

def expect(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        sys.exit(1)

# --- a synthetic upgrade with instant tests --------------------------------------
uid = "999-selftest-synthetic"
d = engine.UPGRADES_DIR / uid
d.mkdir(parents=True)
(d / "patch.diff").write_text(
    "diff --git a/E2E_SELFTEST.txt b/E2E_SELFTEST.txt\n"
    "new file mode 100644\n"
    "index 0000000000000000000000000000000000000000..3b18e512dba79e4c8300dd08aeb37f8e728b8dad\n"
    "--- /dev/null\n"
    "+++ b/E2E_SELFTEST.txt\n"
    "@@ -0,0 +1 @@\n"
    "+hello from the ship manager e2e\n")
(d / "meta.json").write_text(json.dumps({
    "id": uid, "title": "synthetic selftest", "commit_message": "e2e selftest commit",
    "files": ["E2E_SELFTEST.txt"], "dependencies": [], "tests": ["true"],
    "status": "READY", "schema_version": 2, "base_commit": engine.head_sha()}))
# The clone is throwaway - commit the queue addition there so preflight sees a clean tree.
man = engine.load_manifest()
man["upgrades"] = man.get("upgrades", []) + [uid]
engine.write_json(engine.MANIFEST_PATH, man)
subprocess.run(["git", "add", "-A", "upgrade-queue"], check=True)
subprocess.run(["git", "-c", "user.email=e2e@local", "-c", "user.name=e2e",
                "commit", "-qm", "e2e synthetic upgrade"], check=True)

# --- dirty-tree refusal ----------------------------------------------------------
pathlib.Path("README.md").write_text(pathlib.Path("README.md").read_text() + "\n# dirty\n")
r = engine.ship_prepare(uid)
expect(r.get("stage") == "clean-check" and not r.get("ok"), f"dirty tree refused (stage={r.get('stage')})")
expect(not pathlib.Path("E2E_SELFTEST.txt").exists(), "refusal applied nothing")
subprocess.run(["git", "checkout", "--", "README.md"], check=True)

# --- queue bookkeeping must NOT block shipping ------------------------------------
mp = pathlib.Path("upgrade-queue/manifest.json")
mp.write_text(mp.read_text() + "\n")
r = engine.ship_prepare(uid)
expect(r.get("ok"), "dirty upgrade-queue/ bookkeeping does not block shipping")
r = engine.ship_abort(uid)
expect(r.get("ok"), "abort clean after queue-dirty prepare")
subprocess.run(["git", "checkout", "--", "upgrade-queue/manifest.json"], check=True)

# --- prepare -> tamper -> commit refusal ------------------------------------------
r = engine.ship_prepare(uid)
expect(r.get("ok"), f"prepare ok (stage={r.get('stage')}: {r.get('message','')[:120]})")
pathlib.Path("E2E_SELFTEST.txt").write_text("tampered\n")
r = engine.ship_commit(uid)
expect(not r.get("ok") and r.get("stage") == "tamper-check", "tamper detected between prepare and commit")
r = engine.ship_abort(uid)
expect(r.get("ok") and not pathlib.Path("E2E_SELFTEST.txt").exists(), "abort restored original bytes")

# --- full ship: commit lands, push fails, COMMITTED state, retry succeeds -----------
r = engine.ship_prepare(uid)
expect(r.get("ok"), "prepare ok again after abort")
r = engine.ship_commit(uid)
expect(r.get("ok"), "commit accepted")
expect(r.get("pushed") is False, "push failed as intended (bogus remote)")
meta = json.loads((d / "meta.json").read_text())
expect(meta.get("status") == "READY", "meta.json is NOT churned by shipping")
expect(uid not in engine.load_shipments(), "ledger has no entry while push is pending")
sha = engine.head_sha()
st = engine.load_state()
expect(st.get("committed_upgrade") == uid and st.get("committed_sha") == sha, "pending-push state recorded")
expect(pathlib.Path("E2E_SELFTEST.txt").exists(), "no rollback: content survived push failure")

# restart reconciliation does NOT mark it shipped while remote lacks it
subprocess.run(["git", "fetch", "origin"], capture_output=True)
changed = engine.reconcile_committed()
expect(uid not in changed, "reconcile leaves unpushed commit alone")

# fix the remote, retry push -> SHIPPED
subprocess.run(["git", "init", "--bare", "-q", "/tmp/shipmgr-e2e/origin.git"], check=True)
subprocess.run(["git", "remote", "set-url", "origin", "/tmp/shipmgr-e2e/origin.git"], check=True)
r = engine.ship_retry_push(uid)
expect(r.get("ok"), f"retry push ok ({r.get('message','')[:80]})")
expect(uid in engine.load_shipments(), "ledger records the shipment after push")

# remote actually has it
engine.git("fetch", "-q", "origin")
code, out, _ = engine.git("branch", "-r", "--contains", sha)
expect(code == 0 and any(l.strip() for l in out.splitlines()), "origin really contains the shipped commit")

# reconcile on 'restart' is a no-op now
changed = engine.reconcile_committed()
expect(changed == [], "post-push reconcile is a no-op")

# --- landed-without-receipt: refused, then backfilled ------------------------------
twin = "998-selftest-landed-twin"
td = engine.UPGRADES_DIR / twin
td.mkdir(parents=True)
(td / "patch.diff").write_text((d / "patch.diff").read_text())
(td / "meta.json").write_text(json.dumps({
    "id": twin, "title": "landed twin", "commit_message": "e2e selftest commit",
    "files": ["E2E_SELFTEST.txt"], "dependencies": [], "tests": ["true"],
    "status": "READY", "schema_version": 2, "base_commit": engine.head_sha()}))
man = engine.load_manifest()
man["upgrades"] = man.get("upgrades", []) + [twin]
engine.write_json(engine.MANIFEST_PATH, man)
head_before = engine.head_sha()
r = engine.ship_prepare(twin)
expect(not r.get("ok") and r.get("stage") == "already-landed", f"landed twin refused (stage={r.get('stage')})")
expect(engine.head_sha() == head_before and engine.load_state() == {}, "refusal touched nothing")
found = engine.backfill_landed(write=True)
expect(found.get(twin, {}).get("commit") == sha, "backfill matched the twin to its real commit")
expect(engine.effective_status(twin)[0] == "SHIPPED", "backfilled twin reads SHIPPED")
expect(engine.backfill_landed() == {}, "second backfill is a no-op")

# --- capture on a non-empty queue tip carries only the session's own change ---------
tip = "997-selftest-unshipped-tip"
tipd = engine.UPGRADES_DIR / tip
tipd.mkdir(parents=True)
(tipd / "patch.diff").write_text(
    "diff --git a/TIP.txt b/TIP.txt\n"
    "new file mode 100644\n"
    "index 0000000000000000000000000000000000000000..b218ebde2fc5b78f14aa04eeb42a74b17e2e367d\n"
    "--- /dev/null\n"
    "+++ b/TIP.txt\n"
    "@@ -0,0 +1 @@\n"
    "+tip\n")
(tipd / "meta.json").write_text(json.dumps({
    "id": tip, "title": "unshipped tip", "commit_message": "e2e unshipped tip",
    "files": ["TIP.txt"], "dependencies": [], "tests": ["true"],
    "status": "READY", "schema_version": 2, "base_commit": engine.head_sha()}))
man = engine.load_manifest()
man["upgrades"] = man.get("upgrades", []) + [tip]
engine.write_json(engine.MANIFEST_PATH, man)

s = engine.prepare_session_start("independent")
expect(s.get("ok") and s["session"]["queue_tip"][-1:] == [tip], f"session starts on the unshipped tip ({s})")
swt = pathlib.Path(s["session"]["path"])
expect((swt / "TIP.txt").exists(), "tip content is present in the session worktree")
(swt / "OTHER.txt").write_text("other\n")
c = engine.prepare_session_capture(s["session"]["id"], "996-selftest-independent", "independent",
                                   tests=["true"])
expect(c.get("ok"), f"independent capture ok ({c.get('message', '')[:80]})")
ipatch = (engine.UPGRADES_DIR / "996-selftest-independent" / "patch.diff").read_text()
expect("TIP.txt" not in ipatch and "OTHER.txt" in ipatch, "captured patch excludes the tip's content")
expect(c["dependencies"] == [], "no false dependency on the unrelated tip")

s = engine.prepare_session_start("stacked")
swt = pathlib.Path(s["session"]["path"])
(swt / "TIP.txt").write_text("tip\nstacked\n")
c = engine.prepare_session_capture(s["session"]["id"], "995-selftest-stacked", "stacked",
                                   commit_message="e2e stacked", tests=["true"])
spatch = (engine.UPGRADES_DIR / "995-selftest-stacked" / "patch.diff").read_text()
expect(c.get("ok") and c["dependencies"] == [tip], "stacked capture depends on the tip it edits")
expect("OTHER.txt" not in spatch and "+stacked" in spatch and "new file" not in spatch,
       "stacked patch is just its own one-line change")
r = engine.dry_run("995-selftest-stacked")
expect(r.get("ok") and r.get("applied_ancestors") == [tip], f"stacked dry-run applies on tip ({r.get('message', '')[:100]})")

print("\nALL CLONE E2E CHECKS PASSED")
PYEOF
echo "=== e2e done; clone left at /tmp/shipmgr-e2e for inspection ==="
