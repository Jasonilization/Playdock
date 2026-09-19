#!/bin/bash
# Launches the Ship Manager dashboard - cwd-independent (resolves the repo root from this
# script's own location, same pattern as build_app.sh), so `./Scripts/ship_manager.sh` works
# from anywhere instead of requiring you to `cd` into the repo root first.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/upgrade-queue/ship_manager/server.py"
