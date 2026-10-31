#!/usr/bin/env python3
"""Ship Manager - dashboard + ship controller for the upgrade queue. Stdlib only.

Run:   python3 upgrade-queue/ship_manager/server.py   (or Scripts/ship_manager.sh)
Open:  http://127.0.0.1:8765

Architecture (v2): all real logic lives in engine.py. Every potentially-slow operation
(dry-run full build, prepare build+tests, verify-all) runs synchronously per request but
the UI disables buttons while one is in flight; tree-mutating ops additionally serialize
on TREE_LOCK inside the engine.

The model in one paragraph: upgrades form a DAG; statuses are derived (SHIPPED / READY /
WAITING with reasons / HOLD / COMMITTED-pending-push). Dry runs and AI preparation happen
exclusively in detached throwaway git worktrees under .git/shipmgr-worktrees/ - the main
worktree is only ever touched by an explicit Ship, guarded by preflight + byte snapshots +
tamper checks, and every failure path restores originals instead of leaving rubble.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import engine

STATIC_DIR = Path(__file__).resolve().parent / "static"
PORT = int(os.environ.get("SHIPMGR_PORT", "8765"))


def api_list_upgrades():
    metas = engine.all_metas()
    out = []
    for uid in engine.topo_order():
        m = metas[uid]
        eff, missing = engine.effective_status(uid, metas)
        item = dict(m)
        item["effective_status"] = eff
        item["blocked_by"] = engine.blocked_reasons(uid, metas) if eff == "WAITING" else []
        out.append(item)
    return out


def api_get_upgrade(uid):
    m = engine.load_meta(uid)
    eff, _ = engine.effective_status(uid)
    dep_details = []
    metas = engine.all_metas()
    for d in m.get("dependencies", []):
        dm = metas.get(d)
        dep_details.append({
            "id": d,
            "title": dm.get("title") if dm else "(missing)",
            "status": (dm.get("status") if dm else "missing"),
            "files": dm.get("files", []) if dm else [],
        })
    dependents = [u for u, mm in metas.items() if uid in mm.get("dependencies", [])]
    return {
        "meta": m,
        "patch": engine.load_patch(uid),
        "notes": engine.load_notes(uid),
        "effective_status": eff,
        "blocked_by": engine.blocked_reasons(uid, metas),
        "dependency_details": dep_details,
        "required_by": sorted(dependents),
    }


def api_next_ready():
    metas = engine.all_metas()
    counts = {"SHIPPED": 0, "READY": 0, "WAITING": 0, "COMMITTED": 0, "HOLD": 0}
    next_up = None
    for uid in engine.topo_order():
        eff, _ = engine.effective_status(uid, metas)
        counts[eff] = counts.get(eff, 0) + 1
        if next_up is None and eff == "READY":
            next_up = metas[uid]
    total = len(engine.load_manifest().get("upgrades", []))
    return {"next": next_up, "counts": counts, "total": total,
            "shipped_count": counts["SHIPPED"], "ready_count": counts["READY"],
            "blocked_count": counts["WAITING"] + counts.get("HOLD", 0)}


def api_repo_status():
    entries = engine._porcelain()
    branch = engine.git("rev-parse", "--abbrev-ref", "HEAD")[1].strip()
    return {
        "repo_root": str(engine.REPO_ROOT),
        "branch": branch,
        "head": engine.head_sha(),
        "entries": entries,
        "state": engine.load_state(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path in ("/", "/index.html"):
                return self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            if path == "/app.js":
                return self._send_file(STATIC_DIR / "app.js", "application/javascript; charset=utf-8")
            if path == "/app.css":
                return self._send_file(STATIC_DIR / "app.css", "text/css; charset=utf-8")
            if path == "/api/upgrades":
                return self._send_json(api_list_upgrades())
            if path == "/api/next":
                return self._send_json(api_next_ready())
            if path.startswith("/api/upgrades/"):
                uid = path[len("/api/upgrades/"):]
                return self._send_json(api_get_upgrade(uid))
            if path == "/api/state":
                return self._send_json(engine.load_state())
            if path == "/api/repo-root":
                return self._send_json({"repo_root": str(engine.REPO_ROOT)})
            if path == "/api/repo-status":
                return self._send_json(api_repo_status())
            if path == "/api/verify-all/status":
                return self._send_json(engine.verify_all_status())
            if path == "/api/sessions":
                return self._send_json({"sessions": list(engine.prepare_session_gc().values())})
            self._send_json({"error": "not found"}, status=404)
        except engine.ShipError as e:
            self._send_json(e.as_dict(), status=404 if e.stage == "lookup" else 500)
        except Exception as e:
            self._send_json({"error": str(e)}, status=500)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            body = self._read_json_body()
            if path.startswith("/api/upgrades/"):
                rest = path[len("/api/upgrades/"):]
                if rest.endswith("/dry-run"):
                    return self._send_json(engine.dry_run(rest[:-len("/dry-run")]))
                if rest.endswith("/ship/prepare"):
                    return self._send_json(engine.ship_prepare(rest[:-len("/ship/prepare")]))
                if rest.endswith("/ship/commit"):
                    return self._send_json(engine.ship_commit(rest[:-len("/ship/commit")],
                                                              body.get("commit_message")))
                if rest.endswith("/ship/abort"):
                    return self._send_json(engine.ship_abort(rest[:-len("/ship/abort")]))
                if rest.endswith("/ship/retry-push"):
                    return self._send_json(engine.ship_retry_push(rest[:-len("/ship/retry-push")]))
            if path == "/api/verify-all/start":
                return self._send_json(engine.verify_all_start())
            if path == "/api/prepare-session/start":
                return self._send_json(engine.prepare_session_start(body.get("title", "")))
            if path == "/api/prepare-session/capture":
                return self._send_json(engine.prepare_session_capture(
                    body.get("session", ""), body.get("slug", ""),
                    body.get("title", ""), body.get("description", ""),
                    body.get("category", ""), body.get("commit_message", ""),
                    body.get("tests"), body.get("risk", "low")))
            if path == "/api/prepare-session/discard":
                return self._send_json(engine.prepare_session_discard(body.get("session", "")))
            self._send_json({"error": "not found"}, status=404)
        except engine.ShipError as e:
            self._send_json(e.as_dict(), status=400)
        except Exception as e:
            self._send_json({"error": str(e)}, status=500)


def main():
    reconciled = engine.reconcile_committed()
    if reconciled:
        print(f"reconciled pushes: {', '.join(reconciled)} -> SHIPPED", flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Ship Manager running at http://127.0.0.1:{PORT}", flush=True)
    print(f"Repo root: {engine.REPO_ROOT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
