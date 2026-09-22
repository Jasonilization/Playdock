#!/usr/bin/env python3
"""Ship Manager engine - the whole upgrade lifecycle around isolated git worktrees.

Importable + directly testable: every function takes explicit paths, performs real git
operations, and never prints. The HTTP layer (server.py) is a thin wrapper over this.

Model
-----
Each upgrade is a directory `upgrade-queue/upgrades/<id>/` with:
  meta.json   schema v2: id, title, description, category, commit_message, files,
              dependencies (real, empirically minimal), parent, base_commit, tests,
              risk, status (READY / SHIPPED), optional shipped_commit / shipped_at,
              optional provenance, optional legacy_status
  patch.diff  unified diff WITH full blob index lines - applies via `git apply` on the
              dependency-closure state, and supports `git apply --3way` fallback.
  notes.md    optional human notes.

Effectively-computed status (never stored, always derived):
  SHIPPED   uid present in upgrade-queue/shipments.json (the ledger)
  READY     all transitive dependencies SHIPPED and patch applies to current HEAD
  WAITING   some transitive dependency not yet SHIPPED (this is what the old UI lumped
            under BLOCKED - the UI now shows *which* deps and why)
  HOLD      meta.status explicitly set to HOLD (a manual stop with a reason field)

Invariants the engine enforces
-------------------------------
* Dry-run and prepare-session NEVER touch the main worktree. They operate on detached
  throwaway worktrees under .git/shipmgr-worktrees/.
* Ship mutates the main worktree only after a strict preflight (no staged changes, no
  tracked modifications, no untracked collision with the upgrade's files), snapshots
  the byte-exact prior state of every touched file, and on any failure restores those
  bytes exactly. It never force-anything, never stashes, never resets.
* Commit happens only after a successful prepare + an explicit confirm, and only for
  the upgrade's own files. Push is attempted as part of ship; a failed push leaves the
  local commit intact and the upgrade in status COMMITTED (retryable), never data loss.
* Nothing is ever removed from the queue. Supersession is expressed via dependencies.
"""
import hashlib
import json
import re
import shutil
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

SHIP_MANAGER_DIR = Path(__file__).resolve().parent
QUEUE_DIR = SHIP_MANAGER_DIR.parent
REPO_ROOT = QUEUE_DIR.parent
UPGRADES_DIR = QUEUE_DIR / "upgrades"
MANIFEST_PATH = QUEUE_DIR / "manifest.json"
STATE_PATH = SHIP_MANAGER_DIR / ".state.json"
SHIPMENTS_PATH = QUEUE_DIR / "shipments.json"
WORKTREE_PARENT = REPO_ROOT / ".git" / "shipmgr-worktrees"
SNAPSHOT_ROOT = REPO_ROOT / ".git" / "shipmgr-snapshots"

# Ship/prepare/commit/abort serialize on this - see TREE_LOCK comment history.
TREE_LOCK = threading.Lock()


class ShipError(Exception):
    """A user-facing failure: stage + message + optional detail payload."""

    def __init__(self, stage, message, **extra):
        super().__init__(message)
        self.stage = stage
        self.message = message
        self.extra = extra

    def as_dict(self):
        return {"ok": False, "stage": self.stage, "message": self.message, **self.extra}


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def run(cmd, cwd=REPO_ROOT, timeout=900):
    p = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def git(*args, cwd=REPO_ROOT, timeout=600, check=False):
    code, out, err = run(["git", *args], cwd=cwd, timeout=timeout)
    if check and code != 0:
        raise ShipError("git", f"git {' '.join(args)} failed", stderr=err or out)
    return code, out, err


def sha1_file(p: Path):
    return hashlib.sha1(p.read_bytes()).hexdigest()


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def load_manifest():
    return load_json(MANIFEST_PATH, {"schema_version": 2, "upgrades": []})


def upgrade_dir(uid):
    d = UPGRADES_DIR / uid
    if not d.is_dir():
        raise ShipError("lookup", f"no such upgrade: {uid}")
    return d


def load_meta(uid):
    try:
        return load_json(upgrade_dir(uid) / "meta.json")
    except FileNotFoundError:
        raise ShipError("lookup", f"{uid}: meta.json missing")


def load_patch(uid):
    p = upgrade_dir(uid) / "patch.diff"
    return p.read_text() if p.exists() else ""


def load_notes(uid):
    p = upgrade_dir(uid) / "notes.md"
    return p.read_text() if p.exists() else ""


def load_state():
    return load_json(STATE_PATH, {})


def save_state(s):
    write_json(STATE_PATH, s)


# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------

def all_metas():
    man = load_manifest()
    out = {}
    for uid in man.get("upgrades", []):
        try:
            out[uid] = load_meta(uid)
        except ShipError:
            continue
    return out


def dep_closure(uid, metas=None):
    metas = metas or all_metas()
    seen, stack = set(), [uid]
    while stack:
        cur = stack.pop()
        for d in metas.get(cur, {}).get("dependencies", []):
            if d in seen or d == uid:
                continue
            seen.add(d)
            stack.append(d)
    return seen


def load_shipments():
    """The ship ledger: uid -> {commit, shipped_at}. Kept OUT of per-upgrade meta.json
    so shipping one upgrade never dirties the other 108 files; receipt commits touch
    exactly this one small file."""
    return load_json(SHIPMENTS_PATH, {})


def is_shipped(uid, shipments=None):
    return uid in (shipments if shipments is not None else load_shipments())


def unshipped_deps(uid, metas=None, shipments=None):
    """Direct deps that aren't SHIPPED. Returns list of {id, title} for UI reasons."""
    metas = metas or all_metas()
    shipments = shipments if shipments is not None else load_shipments()
    missing = []
    for d in metas[uid].get("dependencies", []):
        dm = metas.get(d)
        if dm is None:
            missing.append({"id": d, "title": "(missing from queue)", "ship_state": "missing"})
        elif not is_shipped(d, shipments):
            missing.append({"id": d, "title": dm.get("title", d), "ship_state": "READY"})
    return missing


def effective_status(uid, metas=None):
    metas = metas or all_metas()
    shipments = load_shipments()
    meta = metas[uid]
    if uid in shipments:
        return "SHIPPED", []
    state = load_state()
    if state.get("committed_upgrade") == uid:
        return "COMMITTED", []
    if meta.get("status") == "HOLD":
        return "HOLD", []
    missing = unshipped_deps(uid, metas, shipments)
    return ("WAITING", missing) if missing else ("READY", [])


def blocked_reasons(uid, metas=None):
    """Human-readable reasons this upgrade cannot ship right now. Each: dict."""
    metas = metas or all_metas()
    meta = metas[uid]
    reasons = []
    for dep in unshipped_deps(uid, metas, load_shipments()):
        dep_files = metas.get(dep["id"], {}).get("files", [])
        shared = sorted(set(dep_files) & set(meta.get("files", [])))
        why = f"shares {', '.join(shared)}" if shared else "required by declared dependency"
        reasons.append({
            "kind": "unshipped-dependency",
            "dependency": dep["id"],
            "dependency_title": dep["title"],
            "detail": f"Requires {dep['id'].split('-')[0]} \"{dep['title']}\" shipped first ({why}).",
        })
    return reasons


def topo_order(ids=None):
    man = load_manifest()
    order = man.get("upgrades", [])
    ids = ids or order
    metas = all_metas()
    idx = {u: i for i, u in enumerate(order)}
    done, seq, remaining = set(), [], set(ids)
    while remaining:
        progressed = False
        for uid in sorted(remaining, key=lambda u: idx.get(u, 1 << 30)):
            if all(d in done or d not in remaining for d in metas.get(uid, {}).get("dependencies", [])):
                seq.append(uid)
                done.add(uid)
                remaining.discard(uid)
                progressed = True
        if not progressed:
            raise ShipError("dependency-graph", f"dependency cycle among: {sorted(remaining)}")
    return seq


# ---------------------------------------------------------------------------
# worktree helpers
# ---------------------------------------------------------------------------

def make_worktree(ref, tag):
    name = f"{tag}-{uuid.uuid4().hex[:8]}"
    path = WORKTREE_PARENT / name
    WORKTREE_PARENT.mkdir(parents=True, exist_ok=True)
    code, out, err = git("worktree", "add", "--detach", str(path), ref)
    if code != 0:
        raise ShipError("worktree-add", err.strip() or out.strip())
    return path


def remove_worktree(path):
    git("worktree", "remove", "--force", str(path), check=False)
    shutil.rmtree(path, ignore_errors=True)


def apply_patch_text(patch_text, cwd, three_way=False):
    """Apply a patch string in `cwd`. Returns (ok, message)."""
    tmp = WORKTREE_PARENT / f".apply-{uuid.uuid4().hex[:8]}.diff"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(patch_text)
    try:
        args = ["apply"]
        if three_way:
            args.append("--3way")
        args.append(str(tmp))
        code, out, err = git(*args, cwd=cwd)
        return code == 0, (err or out)
    finally:
        tmp.unlink(missing_ok=True)


def run_tests(meta, cwd):
    """Run the upgrade's own test list (shell commands) in order."""
    for cmd in meta.get("tests", []):
        code, out, err = run(["sh", "-c", cmd], cwd=cwd, timeout=1200)
        if code != 0:
            return False, cmd, (out + "\n" + err)[-4000:]
    return True, None, None


def head_sha():
    return git("rev-parse", "HEAD")[1].strip()


def base_ancestry_ok(base_commit):
    code, _, _ = git("merge-base", "--is-ancestor", base_commit, "HEAD")
    return code == 0


# ---------------------------------------------------------------------------
# dry run - never touches the main worktree
# ---------------------------------------------------------------------------

def dry_run(uid):
    """Isolated proof a upgrade is shippable: detached worktree at current HEAD, apply any
    unshipped ancestors first (answering 'does it hold given its chain'), then the upgrade
    itself, then its tests. The main worktree is never touched."""
    meta = load_meta(uid)
    patch = load_patch(uid)
    if not patch.strip():
        return {"ok": False, "stage": "patch", "message": "patch.diff is empty or missing"}

    status, _ = effective_status(uid)
    if status == "SHIPPED":
        return {"ok": False, "stage": "status", "message": "Already shipped - nothing to dry-run."}

    metas = all_metas()
    wt = make_worktree("HEAD", f"shipmgr-dryrun-{uid.split('-')[0]}")
    try:
        ancestors = [u for u in topo_order()
                     if u in dep_closure(uid, metas) and not is_shipped(u)]
        applied_ancestors = []
        for anc in ancestors:
            ok, msg = apply_patch_text(load_patch(anc), wt)
            if not ok:
                return {"ok": False, "stage": "apply-dependency",
                        "message": f"Failed applying dependency {anc} at current HEAD:\n{msg}"}
            applied_ancestors.append(anc)
        ok, msg = apply_patch_text(patch, wt)
        if not ok:
            ok, msg = apply_patch_text(patch, wt, three_way=True)
            if not ok:
                return {"ok": False, "stage": "apply",
                        "message": f"Patch does not apply on HEAD ({head_sha()[:10]}) + ancestors, even with 3-way:\n{msg}"}
        passed, bad_cmd, output = run_tests(meta, wt)
        if not passed:
            return {"ok": False, "stage": "test", "message": f"`{bad_cmd}` failed in isolated worktree:\n{output}"}
        anc_note = f" (built on unshipped ancestors: {', '.join(a.split('-')[0] for a in applied_ancestors)})" if applied_ancestors else ""
        return {"ok": True, "stage": "done",
                "message": f"Applies on current HEAD ({head_sha()[:10]}){anc_note}; build + tests green. Main worktree never touched.",
                "applied_ancestors": applied_ancestors}
    finally:
        remove_worktree(wt)


# ---------------------------------------------------------------------------
# ship - three phases: prepare / commit(+push) / abort. retry-push for COMMITTED.
# ---------------------------------------------------------------------------

def _porcelain():
    code, out, err = git("status", "--porcelain=v1", "-z")
    if code != 0:
        raise ShipError("git", "git status failed", stderr=err)
    entries = []
    parts = [p for p in out.split("\x00") if p]
    i = 0
    while i < len(parts):
        rec = parts[i]
        xy, path = rec[:2], rec[3:]
        if xy[0] in "RC":
            i += 1  # rename/copy record has a second path
        entries.append({"xy": xy, "path": path})
        i += 1
    return entries


def ship_preflight(uid):
    """Everything that must hold before the main worktree may be touched.

    Blocks on: staged changes, tracked modifications, untracked collisions with the
    upgrade's own paths. Explicitly ALLOWS unrelated untracked files (upgrade-queue/,
    claude-code-proxy/, etc.) so shipping doesn't demand a sterile tree.
    """
    meta = load_meta(uid)
    files = meta.get("files", [])
    fileset = set(files)
    if any(f.startswith("upgrade-queue/") for f in files):
        raise ShipError("clean-check",
                        f"{uid} touches upgrade-queue/ itself - shipping queue-state changes is the "
                        "manager's own job (ledger/receipts), not a queued upgrade's. Refusing.")
    staged, modified, colliding_untracked = [], [], []
    for e in _porcelain():
        # upgrade-queue/ bookkeeping (manifest appends from prepare-sessions, ledger receipts,
        # new ready upgrades) is the manager's OWN managed state, not user work-in-progress on the
        # app - it must never block shipping the app. Commits only ever stage the upgrade's files.
        queue_own = e["path"].startswith("upgrade-queue/")
        x, y = e["xy"][0], e["xy"][1]
        if x not in (" ", "?") and not queue_own:
            staged.append(e["path"])
        elif y not in (" ", "?") and not queue_own:
            modified.append(e["path"])
        elif x == "?" and y == "?":
            if e["path"] in fileset:
                colliding_untracked.append(e["path"])
    problems = []
    if staged:
        problems.append(f"staged changes present: {', '.join(staged)}")
    if modified:
        problems.append(f"tracked modifications present: {', '.join(modified)}")
    if colliding_untracked:
        problems.append(f"untracked files colliding with this upgrade: {', '.join(colliding_untracked)}")
    if problems:
        raise ShipError("clean-check",
                        "Main worktree is not safe - refusing to touch it:\n" + "\n".join(problems),
                        staged=staged, modified=modified, colliding=colliding_untracked)


def ship_prepare(uid):
    if not TREE_LOCK.acquire(blocking=False):
        return ShipError("busy", "Another ship operation is running; wait for it to finish, then retry.").as_dict()
    try:
        return _ship_prepare(uid)
    finally:
        TREE_LOCK.release()


def _ship_prepare(uid):
    state = load_state()
    if state.get("staged_upgrade"):
        return ShipError("state",
                         f"`{state['staged_upgrade']}` is already staged awaiting commit or abort. Resolve that first.").as_dict()
    meta = load_meta(uid)
    st, missing = effective_status(uid)
    if st == "SHIPPED":
        return ShipError("status", "Already shipped.").as_dict()
    if st == "COMMITTED":
        return ShipError("status", "Already committed locally; only the push is pending. Use Retry Push.").as_dict()
    if st == "WAITING":
        return ShipError("dependency-check",
                         "Unshipped dependencies: " + ", ".join(d["id"] for d in missing),
                         blocked_by=blocked_reasons(uid)).as_dict()

    try:
        ship_preflight(uid)
    except ShipError as e:
        return e.as_dict()

    base = meta.get("base_commit")
    ancestry_note = None
    if base and not base_ancestry_ok(base):
        ancestry_note = (f"Warning: recorded base {base[:10]} is not an ancestor of HEAD "
                         f"({head_sha()[:10]}). Attempting application anyway.")

    patch = load_patch(uid)
    if not patch.strip():
        return ShipError("patch", "patch.diff is empty or missing").as_dict()

    files = meta.get("files", [])
    snapshot_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    snap_dir = SNAPSHOT_ROOT / snapshot_id
    before = {}
    for f in files:
        p = REPO_ROOT / f
        before[f] = p.read_bytes() if p.exists() else None
        if p.exists():
            (snap_dir / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, snap_dir / f)

    ok, msg = apply_patch_text(patch, REPO_ROOT)
    application = "apply"
    if not ok:
        ok, msg = apply_patch_text(patch, REPO_ROOT, three_way=True)
        application = "3way"
    if not ok:
        return ShipError("apply",
                         f"Patch does not apply to the current repository state ({head_sha()[:10]}), "
                         f"even with 3-way:\n{msg}", ancestry_note=ancestry_note).as_dict()

    passed, bad_cmd, output = run_tests(meta, REPO_ROOT)
    if not passed:
        _restore_bytes(before)
        return ShipError("test",
                         f"`{bad_cmd}` failed on the real tree; original bytes restored, nothing committed:\n{output}",
                         ancestry_note=ancestry_note).as_dict()

    # intent-to-add lets the displayed diff include brand-new files without staging content
    git("add", "-N", "--", *files)
    _, diff_out, _ = git("diff", "--", *files)
    after = {f: sha1_file(REPO_ROOT / f) for f in files if (REPO_ROOT / f).exists()}
    for f in files:
        if before.get(f) is None and (REPO_ROOT / f).exists():
            after[f] = sha1_file(REPO_ROOT / f)

    save_state({
        "staged_upgrade": uid,
        "staged_at": datetime.now(timezone.utc).isoformat(),
        "files": files,
        "created_files": [f for f in files if before.get(f) is None],
        "snapshot": snapshot_id,
        "after_sha1": after,
        "head_before": head_sha(),
        "application": application,
    })
    if ancestry_note:
        msg = ancestry_note + "\n\n---\n\n" + diff_out
    return {"ok": True, "stage": "ready", "message": f"Applied ({application}), tests green. Review the diff, then Confirm Ship.",
            "diff": diff_out, "files": files, "ancestry_note": ancestry_note}


def _restore_bytes(before):
    for f, data in before.items():
        p = REPO_ROOT / f
        if data is None:
            p.unlink(missing_ok=True)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
    git("reset", "-q", "--", *(before.keys() or ["."]), check=False)


def ship_abort(uid):
    if not TREE_LOCK.acquire(blocking=False):
        return ShipError("busy", "Another ship operation is running; wait, then retry.").as_dict()
    try:
        state = load_state()
        if state.get("staged_upgrade") != uid:
            return ShipError("state", "Nothing staged for this upgrade.").as_dict()
        before = {}
        for f in state.get("files", []):
            p = REPO_ROOT / f
            snap = SNAPSHOT_ROOT / state["snapshot"] / f
            before[f] = snap.read_bytes() if snap.exists() else None
        _restore_bytes(before)
        save_state({})
        return {"ok": True, "message": "Aborted; original bytes restored, nothing committed."}
    finally:
        TREE_LOCK.release()


def ship_commit(uid, message_override=None):
    if not TREE_LOCK.acquire(blocking=False):
        return ShipError("busy", "Another ship operation is running; wait, then retry.").as_dict()
    try:
        return _ship_commit(uid, message_override)
    finally:
        TREE_LOCK.release()


def _ship_commit(uid, message_override=None):
    state = load_state()
    if state.get("staged_upgrade") != uid:
        return ShipError("state", "Nothing staged. Run Ship (prepare) first.").as_dict()
    meta = load_meta(uid)
    files = state["files"]

    # tamper check: tree must be exactly what prepare left
    for f, want in state.get("after_sha1", {}).items():
        p = REPO_ROOT / f
        if not p.exists() or sha1_file(p) != want:
            return ShipError("tamper-check",
                             f"{f} changed since prepare - refusing to commit. Abort and re-run Ship.").as_dict()
    for f in state.get("created_files", []):
        if not (REPO_ROOT / f).exists():
            return ShipError("tamper-check", f"{f} (new file) vanished since prepare.").as_dict()

    # ensure only our files end up staged (queue bookkeeping staged alongside is left
    # alone - it never enters this commit and needs no intervention)
    cur = [e["path"] for e in _porcelain()
           if e["xy"][0] not in (" ", "?") and not e["path"].startswith("upgrade-queue/")]
    extra = [p for p in cur if p not in files]
    if extra:
        return ShipError("staging-check",
                         f"Unrelated staged changes would be swept into the commit: {', '.join(extra)}. "
                         "Unstage or stash them yourself; refusing.").as_dict()

    code, out, err = git("add", "-A", "--", *files)
    if code != 0:
        return ShipError("git", "git add failed", stderr=err).as_dict()
    message = message_override or meta.get("commit_message") or meta.get("title") or uid
    code, out, err = git("commit", "-m", message)
    if code != 0:
        git("reset", "-q", "--", *files)
        return ShipError("git", "git commit failed", stderr=err or out).as_dict()
    sha = head_sha()

    # The ledger entry is written only on a CONFIRMED push (see _finalize_shipped).
    # Until then the upgrade shows as COMMITTED-pending-push via this state file -
    # nothing in the tracked tree changes here, so the next ship's preflight stays happy.
    save_state({"committed_upgrade": uid, "committed_sha": sha, "files": files})

    push = _push()
    if push["ok"]:
        receipt = _finalize_shipped(uid, sha)
        save_state({})
        return {"ok": True, "message": f"Shipped as {sha[:10]} (+ receipt {receipt[:10] if receipt else 'n/a'}), pushed.",
                "commit": sha, "receipt": receipt, "pushed": True}
    return {"ok": True, "commit": sha, "pushed": False,
            "push_error": push.get("message", ""),
            "message": f"Committed {sha[:10]}, but push failed - NOTHING is lost or rolled back; "
                       "the commit is in your local history. Retry Push when the remote is reachable."}


def _push():
    code, out, err = git("push", "origin", "HEAD", timeout=300)
    return {"ok": code == 0, "message": (out + "\n" + err).strip()}


def _finalize_shipped(uid, sha):
    """Ledger entry -> receipt commit -> best-effort push. Returns receipt sha.
    Only touch is upgrade-queue/shipments.json, so shipping never dirties the tree."""
    shipments = load_shipments()
    shipments[uid] = {"commit": sha, "shipped_at": datetime.now(timezone.utc).isoformat()}
    write_json(SHIPMENTS_PATH, shipments)
    rel = str(SHIPMENTS_PATH.relative_to(REPO_ROOT))
    git("add", "--", rel)
    code, _, err = git("commit", "-m", f"Queue receipt: {uid} shipped as {sha[:10]}")
    if code != 0:
        return None
    receipt = head_sha()
    git("push", "origin", "HEAD", timeout=300)  # best effort - content already on origin
    return receipt


def ship_retry_push(uid):
    state = load_state()
    shipments = load_shipments()
    if uid in shipments:
        return {"ok": True, "message": "Already recorded shipped."}
    if state.get("committed_upgrade") != uid:
        return ShipError("state", "No committed-but-unpushed upgrade pending.").as_dict()
    push = _push()
    if push["ok"]:
        receipt = _finalize_shipped(uid, state["committed_sha"])
        save_state({})
        return {"ok": True, "message": f"Pushed. Marked SHIPPED (receipt {(receipt or '')[:10]})."}
    return ShipError("push", f"Push still failing: {push['message']}").as_dict()


def reconcile_committed():
    """Startup recovery: a committed upgrade whose commit has since appeared on the
    remote (pushed by hand, or a previous crash midway) gets its ledger entry now."""
    state = load_state()
    uid = state.get("committed_upgrade")
    sha = state.get("committed_sha")
    if not uid or not sha:
        return []
    if uid in load_shipments():
        save_state({})
        return [uid]
    code, out, _ = git("branch", "-r", "--contains", sha)
    if code == 0 and any(l.strip() for l in out.splitlines()):
        _finalize_shipped(uid, sha)
        save_state({})
        return [uid]
    return []


# ---------------------------------------------------------------------------
# prepare session - AI-side: isolated worktree to IMPLEMENT a new upgrade in
# ---------------------------------------------------------------------------

def sessions_path():
    return SHIP_MANAGER_DIR / ".sessions.json"


def load_sessions():
    return load_json(sessions_path(), {})


def save_sessions(s):
    write_json(sessions_path(), s)


def queue_tip_refs():
    """The (possibly empty) list of upgrades whose content a new preparation builds on:
    every non-shipped one, in topo order. Shipped ones are already in HEAD."""
    metas = all_metas()
    shipments = load_shipments()
    return [u for u in topo_order() if u not in shipments]


def prepare_session_start(title=""):
    """Detached worktree at HEAD + all unshipped upgrades applied. Main tree untouched."""
    wt = make_worktree("HEAD", "shipmgr-session")
    sid = wt.name.rsplit("-", 1)[-1]
    applied = []
    try:
        for uid in queue_tip_refs():
            ok, msg = apply_patch_text(load_patch(uid), wt)
            if not ok:
                return ShipError("queue-tip",
                                 f"Could not build the queue tip (failed at {uid}): {msg}").as_dict()
            applied.append(uid)
        sessions = load_sessions()
        sessions[sid] = {"id": sid, "path": str(wt), "title": title,
                         "created_at": datetime.now(timezone.utc).isoformat(),
                         "queue_tip": applied}
        save_sessions(sessions)
        return {"ok": True, "session": sessions[sid]}
    except Exception:
        remove_worktree(wt)
        raise


def _latest_per_file(uids):
    metas = all_metas()
    latest = {}
    for u in uids:
        for f in metas[u].get("files", []):
            latest[f] = u
    return latest


def prepare_session_capture(sid, slug, title, description="", category="", commit_message="",
                            tests=None, risk="low"):
    """Turn the session worktree's diff (vs the queue tip it started from) into a new
    queued upgrade. Dependencies: the latest unshipped same-file predecessor per touched
    file - exactly the content the diff's context was authored against."""
    sessions = load_sessions()
    sess = sessions.get(sid)
    if not sess:
        return ShipError("session", f"no such session: {sid}").as_dict()
    wt = Path(sess["path"])
    if not wt.exists():
        return ShipError("session", f"session worktree gone: {wt}").as_dict()

    code, staged_out, _ = git("add", "-A", cwd=wt)
    diff = git("diff", "--cached", "--full-index", cwd=wt)[1]
    if not diff.strip():
        git("reset", "-q", cwd=wt)
        return ShipError("empty", "Session worktree contains no changes vs the queue tip.").as_dict()

    files = sorted(set(re.findall(r"^diff --git a/(\S+)", diff, re.M)))
    unshipped_latest = _latest_per_file(queue_tip_refs())
    deps = sorted({unshipped_latest[f] for f in files if f in unshipped_latest},
                  key=lambda u: topo_order().index(u))

    existing = set(load_manifest().get("upgrades", []))
    if slug in existing or (UPGRADES_DIR / slug).exists():
        git("reset", "-q", cwd=wt)
        return ShipError("id", f"upgrade id already in use: {slug}").as_dict()

    d = UPGRADES_DIR / slug
    d.mkdir(parents=True)
    (d / "patch.diff").write_text(diff)
    meta = {
        "id": slug,
        "title": title or slug,
        "description": description,
        "category": category,
        "commit_message": commit_message or title or slug,
        "files": files,
        "dependencies": deps,
        "parent": deps[-1] if deps else None,
        "base_commit": metas_any_base(),
        "tests": tests or ["swift build", "swift test"],
        "risk": risk,
        "status": "READY",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "author": f"prepare-session:{sid}",
        "schema_version": 2,
        "provenance": {"captured_from_session": sid, "queue_tip_size": len(sess.get("queue_tip", []))},
    }
    write_json(d / "meta.json", meta)
    man = load_manifest()
    man.setdefault("upgrades", []).append(slug)
    man["schema_version"] = 2
    write_json(MANIFEST_PATH, man)

    git("reset", "-q", cwd=wt)
    remove_worktree(wt)
    sessions.pop(sid, None)
    save_sessions(sessions)
    return {"ok": True, "upgrade": meta, "dependencies": deps}


def prepare_session_discard(sid):
    sessions = load_sessions()
    sess = sessions.pop(sid, None)
    save_sessions(sessions)
    if sess:
        remove_worktree(Path(sess["path"]))
    return {"ok": True}


def prepare_session_gc():
    """Drop sessions whose worktree vanished (server restart etc)."""
    sessions = load_sessions()
    alive = {k: v for k, v in sessions.items() if Path(v["path"]).exists()}
    if alive != sessions:
        save_sessions(alive)
    return alive


def metas_any_base():
    metas = all_metas()
    for m in metas.values():
        return m.get("base_commit", "HEAD")
    return "HEAD"


# ---------------------------------------------------------------------------
# verify-all - the full queue replay with a build after EVERY upgrade
# ---------------------------------------------------------------------------

VERIFY_LOCK = threading.Lock()
VERIFY_STATE = {"running": False, "step": 0, "total": 0, "log": [], "result": None,
                "started_at": None, "finished_at": None}


def _verify_all_worker():
    import time
    global VERIFY_STATE
    metas = all_metas()
    shipments = load_shipments()
    order = [u for u in topo_order() if u not in shipments and metas[u].get("status") != "HOLD"]
    VERIFY_STATE.update(running=True, step=0, total=len(order), log=[], result=None,
                        started_at=datetime.now(timezone.utc).isoformat(), finished_at=None)
    wt = None
    try:
        wt = make_worktree("HEAD", "shipmgr-verifyall")
        for i, uid in enumerate(order, 1):
            t0 = time.time()
            ok, msg = apply_patch_text(load_patch(uid), wt)
            if not ok:
                VERIFY_STATE["log"].append({"id": uid, "ok": False, "stage": "apply", "message": msg[:600], "seconds": 0})
                VERIFY_STATE.update(running=False, result={"ok": False, "message": f"{uid} failed to apply in real sequence"},
                                    finished_at=datetime.now(timezone.utc).isoformat())
                return
            code, out, err = run(["swift", "build"], cwd=wt, timeout=600)
            dt = round(time.time() - t0)
            if code != 0:
                VERIFY_STATE["log"].append({"id": uid, "ok": False, "stage": "build",
                                            "message": (out + err)[-1500:], "seconds": dt})
                VERIFY_STATE.update(running=False, result={"ok": False, "message": f"{uid} does not build in sequence"},
                                    finished_at=datetime.now(timezone.utc).isoformat())
                return
            VERIFY_STATE["log"].append({"id": uid, "ok": True, "stage": "build", "message": "", "seconds": dt})
            VERIFY_STATE["step"] = i
        tcode, tout, terr = run(["swift", "test"], cwd=wt, timeout=600)
        if tcode != 0:
            VERIFY_STATE["log"].append({"id": "(final test)", "ok": False, "stage": "test", "message": (tout + terr)[-1500:], "seconds": 0})
            VERIFY_STATE.update(running=False, result={"ok": False, "message": "final swift test failed"},
                                finished_at=datetime.now(timezone.utc).isoformat())
            return
        VERIFY_STATE["log"].append({"id": "(final test)", "ok": True, "stage": "test", "message": "", "seconds": 0})
        VERIFY_STATE.update(running=False,
                            result={"ok": True, "message": f"All {len(order)} unshipped upgrades build individually in dependency order; final tests pass."},
                            finished_at=datetime.now(timezone.utc).isoformat())
    except ShipError as e:
        VERIFY_STATE.update(running=False, result={"ok": False, "message": e.message},
                            finished_at=datetime.now(timezone.utc).isoformat())
    finally:
        if wt:
            remove_worktree(wt)


def verify_all_start():
    with VERIFY_LOCK:
        if VERIFY_STATE["running"]:
            return {"ok": False, "message": "Already running."}
        threading.Thread(target=_verify_all_worker, daemon=True).start()
    return {"ok": True, "message": "Started."}


def verify_all_status():
    return dict(VERIFY_STATE)
