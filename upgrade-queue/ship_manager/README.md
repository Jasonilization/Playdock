# Ship Manager

A local, stdlib-only dashboard for browsing, dry-running, and shipping the real, independently
reviewable upgrades queued in `upgrade-queue/upgrades/`.

## Run it

```
python3 upgrade-queue/ship_manager/server.py
```

Then open <http://127.0.0.1:8765>.

## What it does

- **Browse/search/filter** every upgrade's real metadata (`meta.json`), patch (`patch.diff`),
  and notes (`notes.md`).
- **Dry Run** applies the patch (plus any unshipped dependencies) in a throwaway `git worktree`,
  runs `swift build -c release` and `swift test`, and reports the result. The real working tree
  is never touched by a dry run.
- **Ship** is two-phase, on purpose:
  1. **Prepare** - refuses unless the working tree is clean (nothing outside `upgrade-queue/`),
     refuses unless every declared dependency is already `SHIPPED`, refuses on a patch conflict,
     applies the patch for real, builds, tests. On any failure it reverts the tree and leaves it
     clean. On success it leaves the patch applied (uncommitted) and shows the real diff.
  2. **Confirm Commit** - only works if that exact upgrade is still the one staged. Creates a
     real `git commit` (message from `meta.json`'s `commit_message`, timestamped now - never
     backdated), marks the upgrade `SHIPPED` with the real commit sha, and clears staging.
  - **Abort** at any point between Prepare and Commit reverts the staged changes back to clean.
- **Push** is a separate, explicit button - shipping only ever commits locally. Never force-pushes.

## Hard rules this tool follows

- Never commits without a human clicking Confirm Commit (which itself asks for a browser
  confirm() before firing).
- Never touches the working tree for a dry-run - isolated `git worktree` only.
- Never ships an upgrade whose dependencies aren't shipped yet.
- Never fabricates or backdates a commit timestamp - commits happen at real ship time.
- Never force-pushes, never rewrites history.
