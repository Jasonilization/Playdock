#!/usr/bin/env python3
"""Ship Manager queue migration to schema v2. Re-runnable; NEVER touches the main
working tree. All reconstruction happens in a throwaway DETACHED git worktree, so
`git reset --hard` probes can never move a branch by accident.

Phase 1  Replay original patches in topo order, one scratch commit per upgrade, and
         capture each upgrade's exact delta as `git diff <tip>^ <tip>`. A patch that
         fails on the stacked state was authored on a different ancestor (the settings-
         panel batch was authored on base+058+107 without the earlier GameModeView
         upgrades, etc.) -> REBASE it: per-file 3-way merge (ours=stacked,
         base=authored, theirs=authored+patch). Conflicts whose base side is empty are
         pure adjacent insertions and resolve by UNION (stacked first, then the new
         upgrade's lines); any other conflict aborts with a report and can be curated
         via upgrade-queue/fixups/<id>/<file> (the full desired merged file).

Phase 2  Discover real minimal dependencies: declared deps (kept - they carry semantic
         intent) + the empirically-smallest set of same-file predecessors required for
         the delta to apply onto its dependency closure. Then REGENERATE every patch
         against exactly that closure, with full blob index lines (`git apply --3way`-able).

Phase 3  Validate: regenerated queue replayed in final topo order must be byte-identical
         to phase 1's final stacked state.

Phase 4  Only if validation passes: write patches, meta.json (schema 2), manifest.json
         (numeric order - verified still topological), and migration-report.json.
"""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
QUEUE_DIR = REPO_ROOT / "upgrade-queue"
UPGRADES_DIR = QUEUE_DIR / "upgrades"
MANIFEST_PATH = QUEUE_DIR / "manifest.json"
FIXUPS_DIR = QUEUE_DIR / "fixups"
SCRATCH_PARENT = REPO_ROOT / ".git" / "shipmgr-worktrees"
SCRATCH = SCRATCH_PARENT / "migrate-v2"
TMP_PATCH = SCRATCH_PARENT / ".incoming.patch"

DRY_RUN = "--dry-run" in sys.argv


def git(*args, cwd=REPO_ROOT, check=True):
    p = subprocess.run(["git", *args], cwd=str(cwd), capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"FAILED: git {' '.join(args)}\n{p.stdout}\n{p.stderr}")
    return p


# --- load queue, snapshot ORIGINAL patch bytes ---------------------------------
manifest = json.loads(MANIFEST_PATH.read_text())
orig_order = [u for u in manifest["upgrades"] if (UPGRADES_DIR / u / "meta.json").exists()]
metas = {u: json.loads((UPGRADES_DIR / u / "meta.json").read_text()) for u in orig_order}
orig_patches = {u: (UPGRADES_DIR / u / "patch.diff").read_text() for u in orig_order}
order_idx = {u: i for i, u in enumerate(orig_order)}


def topo_sort(ids, deps_of, tiebreak=None):
    idx = tiebreak or order_idx
    done, result, remaining = set(), [], set(ids)
    while remaining:
        progressed = False
        for uid in sorted(remaining, key=lambda u: idx.get(u, 1 << 30)):
            if all(d in done or d not in remaining for d in deps_of(uid)):
                result.append(uid)
                done.add(uid)
                remaining.discard(uid)
                progressed = True
        if not progressed:
            raise RuntimeError(f"dependency cycle among: {sorted(remaining)}")
    return result


def files_of(patch_text):
    return sorted(set(re.findall(r"^diff --git a/(\S+)", patch_text, re.M)))


topo = topo_sort(orig_order, lambda u: [d for d in metas[u].get("dependencies", []) if d in metas])
BASE = metas[topo[0]]["base_commit"]

fixed_patches = dict(orig_patches)
# Surgical fix #1: 015's patch duplicated 017's GameModeView change. 017 declares the
# file and depends on 015 -> ownership is 017's; strip the duplicate hunk from 015.
p015 = orig_patches.get("015-swift-gridview-focusedid-contract", "")
if "diff --git a/Sources/ExeDock/Views/GameModeView.swift" in p015:
    fixed_patches["015-swift-gridview-focusedid-contract"] = p015.split(
        "diff --git a/Sources/ExeDock/Views/GameModeView.swift"
    )[0]
    print("fix: 015 - stripped GameModeView hunk duplicated in 017")

# --- detached scratch worktree --------------------------------------------------
SCRATCH_PARENT.mkdir(parents=True, exist_ok=True)
if SCRATCH.exists():
    git("worktree", "remove", "--force", str(SCRATCH), check=False)
    shutil.rmtree(SCRATCH, ignore_errors=True)
git("worktree", "add", "--detach", str(SCRATCH), BASE)


def reset_scratch(ref):
    git("reset", "--hard", "-q", ref, cwd=SCRATCH)
    git("clean", "-fdq", cwd=SCRATCH)


def apply_text(patch_text, check_only=False):
    TMP_PATCH.write_text(patch_text)
    args = ["git", "apply"] + (["--check"] if check_only else []) + [str(TMP_PATCH)]
    r = subprocess.run(args, cwd=str(SCRATCH), capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def file_bytes(f):
    p = SCRATCH / f
    return p.read_bytes() if p.exists() else None


def head():
    return git("rev-parse", "HEAD", cwd=SCRATCH).stdout.strip()


conflicts = []
auto_unions = []

CONFLICT_RE = re.compile(
    r"^<<<<<<< [^\n]*\n(.*?)^\|\|\|\|\|\|\| [^\n]*\n(.*?)^=======\n(.*?)^>>>>>>> [^\n]*\n?",
    re.S | re.M)


def merge3_union(ours: bytes, base: bytes, theirs: bytes, label: str, uid: str, f: str):
    """diff3 merge; pure-additive conflicts (empty base) resolve as ours+theirs."""
    b, o, t = (SCRATCH_PARENT / n for n in (".m3-base", ".m3-ours", ".m3-theirs"))
    b.write_bytes(base)
    o.write_bytes(ours)
    t.write_bytes(theirs)
    r = subprocess.run(["git", "merge-file", "-p", "--diff3",
                        "-L", "stacked queue state", "-L", "authored base", "-L", label,
                        str(o), str(b), str(t)], capture_output=True)
    if r.returncode <= 0:
        return r.returncode, r.stdout
    text = r.stdout.decode(errors="replace")
    regions = list(CONFLICT_RE.finditer(text))
    if len(regions) != r.returncode:
        return r.returncode, r.stdout  # unexpected marker shape - treat as unresolvable
    if all(m.group(2).strip() == "" for m in regions):
        resolved = CONFLICT_RE.sub(lambda m: m.group(1) + m.group(3), text)
        auto_unions.append({"uid": uid, "file": f, "regions": len(regions)})
        return 0, resolved.encode()
    return r.returncode, r.stdout


def orig_closure(dep_set):
    out, stack = set(), list(dep_set)
    while stack:
        d = stack.pop()
        if d in out or d not in metas:
            continue
        out.add(d)
        stack.extend(metas[d].get("dependencies", []))
    return out


def authored_state_ok(uid, dep_set):
    full = orig_closure(dep_set)
    reset_scratch(BASE)
    for d in topo:
        if d in full:
            ok, _ = apply_text(orig_patches[d])
            if not ok:
                return False
    ok, _ = apply_text(orig_patches[uid], check_only=True)
    return ok


def reconstruct_authored_state(uid):
    declared = [d for d in metas[uid].get("dependencies", []) if d in metas]
    same_file = [v for v in topo[: topo.index(uid)]
                 if set(files_of(orig_patches[v])) & set(files_of(orig_patches[uid]))]
    for trial in (set(declared), set(declared) | set(same_file)):
        if authored_state_ok(uid, trial):
            return trial
    dep_set = set(declared)
    for v in same_file:
        dep_set.add(v)
        if authored_state_ok(uid, dep_set):
            return dep_set
    return None


def rebase_onto_stack(uid, files, tip):
    """3-way merge uid's original change onto the stacked tip; commit; return new tip."""
    # CRITICAL: capture `ours` BEFORE any probe - probes reset the scratch away from tip.
    ours = {f: file_bytes(f) for f in files}  # scratch is guaranteed at `tip` on entry
    dep_set = reconstruct_authored_state(uid)
    if dep_set is None:
        print(f"  !! {uid}: cannot reconstruct any authored state")
        return None

    reset_scratch(BASE)
    for d in topo:
        if d in orig_closure(dep_set):
            apply_text(orig_patches[d])
    authored = {f: file_bytes(f) for f in files}
    ok, msg = apply_text(orig_patches[uid])
    if not ok:
        print(f"  !! {uid}: original patch fails on its own authored state: {msg[:200]}")
        return None
    theirs = {f: file_bytes(f) for f in files}

    merged = {}
    for f in files:
        au, ob, th = authored.get(f), ours.get(f), theirs.get(f)
        fixup = FIXUPS_DIR / uid / f
        curated = fixup.exists()
        if au == ob:
            merged[f] = th
        elif au == th:
            merged[f] = ob
        elif au is None:
            merged[f] = th
        elif curated:
            merged[f] = fixup.read_bytes()
            print(f"  {uid}: curated fixup applied for {f}")
        else:
            code, out = merge3_union(ob, au, th, f"{uid} change", uid, f)
            if code != 0:
                conflicts.append((uid, f, out.decode(errors="replace")))
                print(f"  !! {uid}: CONFLICT in {f} ({code} region(s)); curated fixup path: "
                      f"{FIXUPS_DIR}/{uid}/{f}")
                return None
            merged[f] = out
        if curated:
            continue  # curated fixups are authoritative - intentional supersessions allowed
        # Survival invariant: nothing the stack had that the authored base lacked may
        # vanish, and nothing this upgrade adds may vanish. (A bad merge that silently
        # replaces a sibling's insertion otherwise looks "clean" to git.)
        ours_lines = set(ob.decode(errors="replace").splitlines()) if ob else set()
        auth_lines = set(au.decode(errors="replace").splitlines()) if au else set()
        theirs_lines = set(th.decode(errors="replace").splitlines()) if th else set()
        merged_lines = set(merged[f].decode(errors="replace").splitlines()) if merged[f] else set()
        lost_stack = (ours_lines - auth_lines) - merged_lines
        lost_self = (theirs_lines - auth_lines) - merged_lines
        if lost_stack or lost_self:
            conflicts.append((uid, f,
                              f"SURVIVAL VIOLATION\nlost stacked lines: {sorted(lost_stack)[:20]}\n"
                              f"lost upgrade lines: {sorted(lost_self)[:20]}"))
            print(f"  !! {uid}: merge dropped content in {f} "
                  f"({len(lost_stack)} stacked, {len(lost_self)} own lines lost)")
            return None

    reset_scratch(tip)
    for f, data in merged.items():
        p = SCRATCH / f
        if data is None:
            p.unlink(missing_ok=True)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
    git("add", "-A", cwd=SCRATCH)
    git("-c", "user.email=shipmgr@local", "-c", "user.name=shipmgr",
        "commit", "--allow-empty", "-qm", uid, cwd=SCRATCH)
    return head()


try:
    # ---- phase 1 -------------------------------------------------------------
    print("== phase 1: replay originals (rebase on mismatch) ==", flush=True)
    stack_diffs, rebased_ones = {}, []
    tip = BASE
    reset_scratch(tip)
    for uid in topo:
        files = files_of(fixed_patches[uid])
        ok, msg = apply_text(fixed_patches[uid])
        if not ok:
            print(f"  {uid}: stack mismatch -> rebase ({msg.splitlines()[0][:100]})", flush=True)
            new_tip = rebase_onto_stack(uid, files, tip)
            if new_tip is None:
                break
            tip = new_tip
            rebased_ones.append(uid)
        else:
            git("add", "-A", cwd=SCRATCH)
            git("-c", "user.email=shipmgr@local", "-c", "user.name=shipmgr",
                "commit", "--allow-empty", "-qm", uid, cwd=SCRATCH)
            tip = head()
        stack_diffs[uid] = git("diff", "--full-index", f"{tip}^", tip, "--", *files,
                               cwd=SCRATCH).stdout
    if conflicts:
        (QUEUE_DIR / "migration-conflicts.json").write_text(json.dumps(
            [{"uid": u, "file": f, "merged_with_markers": m} for u, f, m in conflicts], indent=2))
        print(f"CONFLICTS: {len(conflicts)} -> migration-conflicts.json; nothing written.")
        sys.exit(3)
    for a in auto_unions:
        print(f"  auto-union: {a['uid']} {a['file']} ({a['regions']} pure-insertion region(s))")

    final_state = {}
    for uid in topo:
        for f in files_of(fixed_patches[uid]):
            b = file_bytes(f)
            if b is not None:
                final_state[f] = hashlib.sha1(b).hexdigest()
    print(f"  replay complete; {len(topo)} upgrades; {len(final_state)} touched files", flush=True)

    # ---- phase 2 -------------------------------------------------------------
    print("== phase 2: dependency discovery + regeneration ==", flush=True)
    files_by = {u: files_of(fixed_patches[u]) for u in topo}
    final_deps, regenerated = {}, {}

    def closure(dep_set):
        out, stack = set(), list(dep_set)
        while stack:
            d = stack.pop()
            if d in out:
                continue
            out.add(d)
            stack.extend(final_deps.get(d, metas[d].get("dependencies", [])))
        return out

    for i, uid in enumerate(topo):
        files = files_by[uid]
        declared = [d for d in metas[uid].get("dependencies", []) if d in metas]
        latest_per_file = {}
        for v in topo[:i]:
            for f in set(files_by[v]) & set(files):
                latest_per_file[f] = v
        candidates = sorted(set(declared) | set(latest_per_file.values()), key=topo.index)
        if uid in rebased_ones:
            candidates = sorted(set(candidates) | {v for v in topo[:i] if set(files_by[v]) & set(files)},
                                key=topo.index)

        cache = {}

        def try_on(dep_set):
            full = frozenset(closure(dep_set))
            if full in cache:
                return cache[full]
            reset_scratch(BASE)
            ok = True
            for d in topo:
                if d in full:
                    ok, _ = apply_text(stack_diffs[d])
                    if not ok:
                        break
            if ok:
                ok, _ = apply_text(stack_diffs[uid], check_only=True)
            cache[full] = ok
            return ok

        if not try_on(set(candidates)):
            print(f"  !! {uid}: fails on full candidate closure; keeping full set", flush=True)
            minimal = list(candidates)
        else:
            minimal = list(candidates)
            for c in sorted([c for c in candidates if c not in declared], key=lambda u: -topo.index(u)):
                if try_on(set(minimal) - {c}):
                    minimal.remove(c)
        final_deps[uid] = minimal
        if set(minimal) != set(declared):
            print(f"  {uid}: deps {metas[uid].get('dependencies', [])} -> {minimal}", flush=True)

        reset_scratch(BASE)
        full = closure(set(minimal))
        for d in topo:
            if d in full:
                ok, msg = apply_text(stack_diffs[d])
                if not ok:
                    print(f"  !! {uid}: closure apply failed at {d}: {msg[:200]}")
                    sys.exit(4)
        git("add", "-A", cwd=SCRATCH)
        t1 = git("write-tree", cwd=SCRATCH).stdout.strip()
        ok, msg = apply_text(stack_diffs[uid])
        if not ok:
            print(f"  !! {uid}: regeneration apply failed: {msg[:300]}")
            sys.exit(4)
        git("add", "-A", cwd=SCRATCH)
        t2 = git("write-tree", cwd=SCRATCH).stdout.strip()
        regenerated[uid] = git("diff", "--full-index", t1, t2, "--", *files, cwd=SCRATCH).stdout

    changed = [u for u in topo if regenerated[u].rstrip() != orig_patches[u].rstrip()]
    dep_changes = {u: {"from": metas[u].get("dependencies", []), "to": final_deps[u]}
                   for u in topo if metas[u].get("dependencies", []) != final_deps[u]}
    print(f"  {len(changed)} regenerated; {len(dep_changes)} dep sets changed", flush=True)

    # ---- phase 3 -------------------------------------------------------------
    print("== phase 3: validation replay of regenerated queue ==", flush=True)
    num_idx = {u: int(u.split("-")[0]) for u in topo}
    new_topo = topo_sort(topo, lambda u: final_deps[u], tiebreak=num_idx)
    reset_scratch(BASE)
    for uid in new_topo:
        ok, msg = apply_text(regenerated[uid])
        if not ok:
            print(f"  FAIL regenerated {uid}: {msg[:300]}")
            sys.exit(5)
    bad = []
    for f, want in final_state.items():
        b = file_bytes(f)
        got = hashlib.sha1(b).hexdigest() if b is not None else None
        if got != want:
            bad.append(f)
    if bad:
        print(f"  FINAL STATE MISMATCH: {bad}")
        sys.exit(6)
    print(f"  byte-identical replay across {len(final_state)} files", flush=True)

    if DRY_RUN:
        print("== dry run: nothing written ==")
        sys.exit(0)

    # ---- phase 4 -------------------------------------------------------------
    file_fixes = {}
    for uid in topo:
        (UPGRADES_DIR / uid / "patch.diff").write_text(regenerated[uid])
        m = metas[uid]
        if sorted(m.get("files", [])) != files_by[uid]:
            file_fixes[uid] = {"from": m.get("files", []), "to": files_by[uid]}
        m["files"] = files_by[uid]
        m["dependencies"] = final_deps[uid]
        m["parent"] = final_deps[uid][-1] if final_deps[uid] else None
        m["schema_version"] = 2
        m["provenance"] = {
            "migrated_at": datetime.now(timezone.utc).isoformat(),
            "original_patch_sha1": hashlib.sha1(orig_patches[uid].encode()).hexdigest(),
            "patch_regenerated": uid in changed,
        }
        if m.get("status") != "SHIPPED":
            m["legacy_status"] = m.get("status")
            m["status"] = "READY"
        (UPGRADES_DIR / uid / "meta.json").write_text(json.dumps(m, indent=2) + "\n")
    manifest["upgrades"] = new_topo
    manifest["schema_version"] = 2
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n")
    report = {
        "migrated_at": datetime.now(timezone.utc).isoformat(),
        "total": len(topo),
        "rebased": rebased_ones,
        "auto_union_resolutions": auto_unions,
        "regenerated": changed,
        "dep_changes": dep_changes,
        "file_fixes": file_fixes,
        "manifest_reordered": new_topo != orig_order,
    }
    (QUEUE_DIR / "migration-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"== done: {len(topo)} migrated | {len(rebased_ones)} rebased | "
          f"{len(changed)} regenerated | {len(dep_changes)} dep changes | {len(file_fixes)} file fixes ==")
finally:
    git("worktree", "remove", "--force", str(SCRATCH), check=False)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    for n in (".incoming.patch", ".m3-base", ".m3-ours", ".m3-theirs"):
        (SCRATCH_PARENT / n).unlink(missing_ok=True)
