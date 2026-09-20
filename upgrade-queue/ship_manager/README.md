# Ship Manager

A local, stdlib-only dashboard for browsing, dry-running, and shipping the real,
independently reviewable upgrades queued in `upgrade-queue/upgrades/`.

## Run it

```
./Scripts/ship_manager.sh        # or: python3 upgrade-queue/ship_manager/server.py
```

Then open <http://127.0.0.1:8765>. (`SHIPMGR_PORT` overrides the port.)

## The model

The queue is a **DAG**, not a flat list. Every upgrade has `meta.json` (schema 2):

```
id, title, description, category, commit_message, files[],
dependencies[]   # REAL deps: declared semantics + empirically-reduced same-file parents
base_commit, tests[], risk, status, provenance
```

and a `patch.diff` regenerated against exactly its dependency closure, with full blob
index lines, so `git apply --3way` always has material to work with.

Statuses are **derived**, never guessed:

- **SHIPPED** — its commit is in history (reconciled against the remote on startup).
- **READY** — every dependency shipped; will apply to current HEAD.
- **WAITING** — shows *which* dependencies are missing and *why* ("Requires 011 … shipped
  first (shares Sources/ExeDock/Views/GameModeView.swift)"). The old flat BLOCKED column
  is gone; blocking is computed from the graph.
- **COMMITTED** — content committed locally, push pending. Nothing is ever rolled back
  on push failure; retry when the remote is reachable. Both commit and receipt survive.
- **HOLD** — manual stop.

## Safety contract (v2)

- **Preparation never touches the main worktree.** Dry-runs and AI prepare-sessions run
  in detached throwaway worktrees under `.git/shipmgr-worktrees/`. Preparing something
  never requires the main tree to be clean.
- **Dry Run** = worktree at current HEAD → apply unshipped ancestors → apply the upgrade
  → run its tests → delete the worktree. The main tree is untouched, always.
- **Ship** = preflight (no staged changes, no tracked modifications; unrelated untracked
  files are fine — upgrade-queue/ and local tools don't block shipping) → byte-exact
  snapshot of every touched file → apply (`--3way` fallback) → run tests → show diff →
  explicit Confirm → commit → automatic queue-receipt commit → push → SHIPPED.
- Any failure before the commit restores the original bytes exactly. After a commit,
  nothing is ever rolled back (a failed push is a safe COMMITTED state + Retry Push).
- A **tamper check** between Prepare and Commit refuses to commit if the staged content
  changed since preparation.
- Shipping creates **two commits**: the content commit (message from `commit_message`)
  and a tiny queue-receipt commit recording the SHIPPED flip, so the tree is clean for
  the next ship. Never force-pushes, never backdates, never rewrites history.

## For AI sessions (preparing new upgrades)

1. `POST /api/prepare-session/start` (or the "+ Prepare-Session Worktree" button) —
   returns a detached worktree already sitting on **HEAD + every unshipped upgrade
   applied** (the queue tip). Implement and test there.
2. `POST /api/prepare-session/capture` with the session id and the new upgrade's
   metadata — the worktree's diff becomes `patch.diff`, dependencies are computed as
   the latest unshipped same-file predecessors (the content your diff's context was
   authored against), and the session worktree is removed.
3. Never hand-edit the main worktree to "prepare" an upgrade — that's the contamination
   this architecture exists to prevent.

## Maintenance tools

- `python3 upgrade-queue/ship_manager/migrate.py [--dry-run]` — the schema-v2 migrator:
  replays the queue, rebases wrong-ancestor patches via 3-way merge, proves survival
  invariants, regenerates patches, validates byte-identical final state, then writes.
  Uses curated resolutions in `upgrade-queue/fixups/<id>/` when a merge has genuine
  semantic conflicts (see `fixups/119-.../_README.md`).
- `bash upgrade-queue/ship_manager/e2e_clone_test.sh` — the refusal/failure battery
  (dirty tree, tamper, abort-restore, failed push, restart reconcile) inside a throwaway
  clone.
- **Verify Whole Queue** button — applies every unshipped upgrade one at a time in
  dependency order in an isolated worktree, building after each single one, exactly
  simulating the one-a-day habit.
