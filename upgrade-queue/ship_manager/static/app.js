(() => {
  const listEl = document.getElementById("upgrade-list");
  const filtersEl = document.getElementById("filters");
  const detailEl = document.getElementById("detail-pane");
  const searchEl = document.getElementById("search");
  const repoPathEl = document.getElementById("repo-path");
  const progressEl = document.getElementById("progress-summary");
  const upNextEl = document.getElementById("up-next-banner");
  const pendingEl = document.getElementById("pending-banner");
  const toolsEl = document.getElementById("tools-banner");

  let allUpgrades = [];
  let selectedId = null;
  let activeFilter = "all";
  let verifyPoll = null;

  const escapeHtml = (s) => (s || "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const riskClass = (r) => `risk-${r || "low"}`;
  const api = async (path, opts) => (await fetch(path, opts)).json();

  function shortId(uid) { return (uid || "").split("-")[0]; }

  function renderFilters() {
    const statuses = ["all", "READY", "WAITING", "SHIPPED", "COMMITTED", "HOLD"];
    filtersEl.innerHTML = statuses.map(s =>
      `<span class="filter-chip ${s === activeFilter ? "active" : ""}" data-filter="${s}">${s === "all" ? "All" : s}</span>`
    ).join("");
    filtersEl.querySelectorAll(".filter-chip").forEach(chip => {
      chip.addEventListener("click", () => {
        activeFilter = chip.dataset.filter;
        renderFilters();
        renderList();
      });
    });
  }

  function renderList() {
    const q = searchEl.value.trim().toLowerCase();
    const filtered = allUpgrades.filter(u =>
      (activeFilter === "all" || u.effective_status === activeFilter) &&
      (!q || `${u.id} ${u.title} ${u.description} ${u.category}`.toLowerCase().includes(q)));
    if (!filtered.length) {
      listEl.innerHTML = `<div class="empty-state">No upgrades match.</div>`;
      return;
    }
    listEl.innerHTML = filtered.map(u => `
      <div class="upgrade-row ${u.id === selectedId ? "selected" : ""}" data-id="${u.id}">
        <div class="row-top">
          <span class="id">${u.id}</span>
          <span class="badge badge-${u.effective_status}"
            ${u.effective_status === "WAITING" ? `title="${escapeHtml(u.blocked_by.map(b => b.detail).join("\n"))}"` : ""}>
            ${u.effective_status}
          </span>
        </div>
        <div class="title">${escapeHtml(u.title)}</div>
        <div class="meta-line">
          <span>${escapeHtml(u.category || "")}</span>
          <span class="${riskClass(u.risk)}">${u.risk || "?"} risk</span>
          ${(u.dependencies || []).length ? `<span class="dep-hint">← ${(u.dependencies || []).map(shortId).join(", ")}</span>` : ""}
        </div>
      </div>`).join("");
    listEl.querySelectorAll(".upgrade-row").forEach(row =>
      row.addEventListener("click", () => selectUpgrade(row.dataset.id)));
  }

  function diffToHtml(diff) {
    return escapeHtml(diff).split("\n").map(line => {
      let cls = "";
      if (line.startsWith("+++") || line.startsWith("---")) cls = "diff-file";
      else if (line.startsWith("@@")) cls = "diff-hunk";
      else if (line.startsWith("+")) cls = "diff-add";
      else if (line.startsWith("-")) cls = "diff-del";
      return `<span class="${cls}">${line}</span>`;
    }).join("\n");
  }

  function opResultHtml(result) {
    if (!result) return "";
    const ok = result.ok;
    const headline = ok ? (result.message || "OK") : `Failed at "${result.stage || "?"}"`;
    return `<div class="op-result ${ok ? "ok" : "fail"}">
      <div>${escapeHtml(headline)}</div>
      ${result.push_error ? `<pre>${escapeHtml(result.push_error)}</pre>` : ""}
      ${!ok && result.message && headline !== result.message ? `<pre>${escapeHtml(result.message)}</pre>` : ""}
      ${ok && result.diff ? `<pre>${diffToHtml(result.diff)}</pre>` : ""}
    </div>`;
  }

  async function selectUpgrade(id) {
    selectedId = id;
    renderList();
    detailEl.innerHTML = `<div class="empty-state"><span class="spinner"></span> Loading…</div>`;
    const [data, state] = await Promise.all([api(`/api/upgrades/${id}`), api("/api/state")]);
    renderDetail(data, state);
  }

  function blockedPanelHtml(blockedBy) {
    if (!blockedBy || !blockedBy.length) return "";
    return `<div class="blocked-panel">
      <div class="blocked-title">Blocked until these ship:</div>
      ${blockedBy.map(b => `
        <div class="blocked-row">
          <span class="dep-chip" data-dep="${b.dependency}">${shortId(b.dependency)}</span>
          <div>
            <div class="blocked-dep-title">${escapeHtml(b.dependency_title)}</div>
            <div class="blocked-detail">${escapeHtml(b.detail)}</div>
          </div>
        </div>`).join("")}
    </div>`;
  }

  function renderDetail(data, state, lastOp) {
    const m = data.meta;
    const eff = data.effective_status;
    const staged = state && state.staged_upgrade === m.id;
    const committedPending = state && state.committed_upgrade === m.id;
    const otherStaged = state && state.staged_upgrade && state.staged_upgrade !== m.id;

    const deps = data.dependency_details || [];
    const depHtml = deps.length ? deps.map(d =>
      `<span class="dep-chip ${d.status === "SHIPPED" ? "dep-shipped" : "dep-unshipped"}" data-dep="${d.id}"
        title="${escapeHtml(d.status)}">${shortId(d.id)}${d.status === "SHIPPED" ? " ✓" : ""}</span>`).join(" ")
      : `<span class="text-dim">none</span>`;

    detailEl.innerHTML = `
      <div class="detail-header">
        <div>
          <h2 class="detail-title">${escapeHtml(m.title)}</h2>
          <div class="detail-id">${m.id} · ${escapeHtml(m.commit_message || "")}</div>
        </div>
        <span class="badge badge-${eff}">${eff}</span>
      </div>
      <div class="detail-description">${escapeHtml(m.description)}</div>

      <div class="meta-grid">
        <div class="meta-cell"><div class="k">Category</div><div class="v">${escapeHtml(m.category || "")}</div></div>
        <div class="meta-cell"><div class="k">Risk</div><div class="v ${riskClass(m.risk)}">${m.risk || "?"}</div></div>
        <div class="meta-cell"><div class="k">Files</div><div class="v">${(m.files || []).length}</div></div>
        <div class="meta-cell"><div class="k">Depends on</div><div class="v dep-row">${depHtml}</div></div>
        <div class="meta-cell"><div class="k">Base</div><div class="v">${(m.base_commit || "").slice(0, 10)}</div></div>
        <div class="meta-cell"><div class="k">Tests</div><div class="v">${(m.tests || []).map(escapeHtml).join(" && ")}</div></div>
        ${m.shipped_commit ? `<div class="meta-cell"><div class="k">Commit</div><div class="v">${m.shipped_commit.slice(0, 10)}</div></div>` : ""}
        ${data.required_by && data.required_by.length ? `<div class="meta-cell"><div class="k">Unblocks</div><div class="v">${data.required_by.map(shortId).join(", ")}</div></div>` : ""}
      </div>

      ${blockedPanelHtml(data.blocked_by)}
      ${staged ? `<div class="op-result ok">Staged: applied + tests green. Review the diff, then <b>Confirm: Commit &amp; Push</b>, or Abort to restore originals.</div>` : ""}
      ${committedPending ? `<div class="op-result ok">Committed locally as ${(state.committed_sha || "").slice(0, 10)}. <b>Push is pending</b> - no data at risk; hit Retry Push when the remote is reachable.</div>` : ""}
      ${otherStaged ? `<div class="op-result fail">Note: ${escapeHtml(state.staged_upgrade)} is currently staged. Resolve it (commit or abort) before preparing another.</div>` : ""}

      <div class="action-bar">
        <button id="btn-dry-run" ${eff === "SHIPPED" || eff === "WAITING" ? "disabled" : ""}
          title="Applies on a detached worktree at current HEAD, runs this upgrade's tests, discards everything">Dry Run (isolated)</button>
        ${eff === "READY" && !staged && !committedPending ? `<button id="btn-prepare" class="primary">🚀 Ship: Prepare</button>` : ""}
        ${staged ? `<button id="btn-commit" class="primary">Confirm: Commit &amp; Push</button><button id="btn-abort" class="danger">Abort</button>` : ""}
        ${committedPending ? `<button id="btn-retry-push" class="primary">Retry Push</button>` : ""}
      </div>

      <div id="op-result">${lastOp ? opResultHtml(lastOp) : ""}</div>

      <div class="section-label">Files</div>
      <div class="notes-body mono">${(m.files || []).join("\n")}</div>

      <div class="section-label">Patch</div>
      <div class="diff-view">${diffToHtml(data.patch || "(empty)")}</div>

      ${data.notes ? `<div class="section-label">Notes</div><div class="notes-body">${escapeHtml(data.notes)}</div>` : ""}
    `;

    detailEl.querySelectorAll(".dep-chip[data-dep]").forEach(chip =>
      chip.addEventListener("click", () => selectUpgrade(chip.dataset.dep)));

    const on = (id, fn) => { const b = document.getElementById(id); if (b) b.addEventListener("click", fn); };
    on("btn-dry-run", () => runOp(m.id, "dry-run", "Dry-running in an isolated worktree (build + tests)…"));
    on("btn-prepare", () => runOp(m.id, "ship/prepare", "Preflight → apply to main tree → tests…"));
    on("btn-commit", async () => {
      if (!confirm(`Commit now and push to origin?\n\n"${m.commit_message}"`)) return;
      await runOp(m.id, "ship/commit", "Committing and pushing…");
    });
    on("btn-abort", () => runOp(m.id, "ship/abort", "Restoring original bytes…"));
    on("btn-retry-push", () => runOp(m.id, "ship/retry-push", "Pushing…"));
  }

  async function runOp(id, opPath, loadingMessage) {
    detailEl.querySelectorAll(".action-bar button").forEach(b => b.disabled = true);
    detailEl.querySelector("#op-result").innerHTML =
      `<div class="op-result"><span class="spinner"></span> ${escapeHtml(loadingMessage)}</div>`;
    const result = await api(`/api/upgrades/${id}/${opPath}`, { method: "POST" });
    const [data, state] = await Promise.all([api(`/api/upgrades/${id}`), api("/api/state")]);
    await refreshList();
    await refreshBanners();
    renderDetail(data, state, result);
  }

  async function refreshList() {
    allUpgrades = await api("/api/upgrades");
    renderList();
    await refreshUpNext();
  }

  async function refreshUpNext() {
    const data = await api("/api/next");
    const c = data.counts;
    progressEl.textContent =
      `${c.SHIPPED || 0} shipped · ${c.READY || 0} ready · ${c.WAITING || 0} waiting · ${data.total} total`;
    if (!data.next) {
      upNextEl.hidden = false;
      upNextEl.classList.add("done");
      upNextEl.innerHTML = `<span class="title">Nothing ready to ship right now.</span>
        <span class="meta">${c.WAITING || 0} waiting on dependencies.</span>`;
      return;
    }
    upNextEl.hidden = false;
    upNextEl.classList.remove("done");
    const n = data.next;
    upNextEl.innerHTML = `
      <span class="label">Up Next</span>
      <span class="title">${escapeHtml(n.title)}</span>
      <span class="meta">${n.id} · ${escapeHtml(n.category || "")} · ${n.risk || "?"} risk</span>
      <span class="spacer"></span>
      <button id="btn-ship-next" class="primary">Review &amp; Ship This</button>`;
    document.getElementById("btn-ship-next").addEventListener("click", () => selectUpgrade(n.id));
  }

  async function refreshBanners() {
    const state = await api("/api/state");
    if (state.committed_upgrade) {
      pendingEl.hidden = false;
      pendingEl.innerHTML = `<span class="label">Push pending</span>
        <span class="meta">${escapeHtml(state.committed_upgrade)} committed as ${(state.committed_sha || "").slice(0, 10)} - not on origin yet.</span>
        <span class="spacer"></span>
        <button id="btn-banner-retry" class="primary">Retry Push</button>`;
      document.getElementById("btn-banner-retry").addEventListener("click", async () => {
        const r = await api(`/api/upgrades/${state.committed_upgrade}/ship/retry-push`, { method: "POST" });
        alert(r.message);
        await refreshAll();
      });
    } else {
      pendingEl.hidden = true;
    }
  }

  // ---- tools: verify-all + prepare session ----------------------------------
  function renderTools() {
    toolsEl.hidden = false;
    toolsEl.innerHTML = `
      <span class="label">Tools</span>
      <button id="btn-verify-all">Verify Whole Queue</button>
      <span id="verify-status" class="meta"></span>
      <span class="spacer"></span>
      <button id="btn-session-start">+ Prepare-Session Worktree</button>
      <span id="session-status" class="meta"></span>`;
    document.getElementById("btn-verify-all").addEventListener("click", startVerifyAll);
    document.getElementById("btn-session-start").addEventListener("click", startSession);
  }

  async function startVerifyAll() {
    const r = await api("/api/verify-all/start", { method: "POST" });
    if (!r.ok) { alert(r.message); return; }
    pollVerify();
  }

  function pollVerify() {
    if (verifyPoll) clearInterval(verifyPoll);
    verifyPoll = setInterval(async () => {
      const s = await api("/api/verify-all/status");
      const el = document.getElementById("verify-status");
      if (!el) { clearInterval(verifyPoll); return; }
      if (s.running) {
        el.textContent = `verifying ${s.step}/${s.total}…`;
      } else {
        clearInterval(verifyPoll);
        const lastBad = (s.log || []).filter(l => !l.ok).slice(-1)[0];
        el.innerHTML = s.result
          ? `${s.result.ok ? "✓" : "✗"} ${escapeHtml(s.result.message)}${lastBad ? ` (${escapeHtml((lastBad.message || "").slice(0, 200))})` : ""}`
          : "";
      }
    }, 1500);
  }

  async function startSession() {
    const title = prompt("Working title for this preparation session (the implementation itself happens in the worktree it gives you):");
    if (title === null) return;
    const r = await api("/api/prepare-session/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
    });
    if (!r.ok) { alert(r.message || "failed"); return; }
    alert(`Session worktree ready - main tree untouched.\n\n${r.session.path}\n\nIt starts at current HEAD + every unshipped upgrade already applied, so build on top of whatever's in flight. When done: use /api/prepare-session/capture (or ask your agent) to turn the diff into a new queued upgrade; the session id is ${r.session.id}.`);
    document.getElementById("session-status").textContent = `session ${r.session.id} open`;
  }

  async function refreshAll() {
    await refreshList();
    await refreshBanners();
  }

  searchEl.addEventListener("input", renderList);
  renderFilters();
  renderTools();
  refreshAll();
  api("/api/repo-root").then(r => { repoPathEl.textContent = r.repo_root; });
})();
