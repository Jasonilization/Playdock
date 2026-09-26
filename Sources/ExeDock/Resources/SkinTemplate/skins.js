// Six Playdocks - real per-skin card/topbar markup, ported from the original HTML mockups
// (ten-playdocks.html) and parameterized on real library data instead of the mockup's fake GAMES
// array. skins.css is the CSS half of the same port. Swift calls window.PlaydockRender(skinKey,
// gamesJSON, meta) after every load and whenever the underlying data changes; clicks route back to
// Swift through window.webkit.messageHandlers.playdock.postMessage(...) - the app's own established
// "tap a card opens the full Game Detail view" convention, not the mockup's own inline Launch button
// (that was a deliberate, hard-won fix from live feedback, kept intact here rather than reverted).
'use strict';

function esc(s) {
  return (s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// Deterministic placeholder gradient for a game with no fetched artwork - keyed off its id so the
// same game always gets the same color, matching the native SwiftUI layouts' own placeholderTile.
function hueForID(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) { h = (h * 31 + id.charCodeAt(i)) >>> 0; }
  return h % 360;
}
function tile(hue, sat, angle) {
  return `linear-gradient(${angle || 135}deg, hsl(${hue} ${sat}% 38%), hsl(${(hue + 40) % 360} ${sat}% 20%))`;
}
function artStyle(gm, sat, angle) {
  if (gm.art) return `background-image:url('${gm.art}')`;
  return `background-image:${tile(hueForID(gm.id), sat || 45, angle)}`;
}

function postClick(id) {
  try { window.webkit.messageHandlers.playdock.postMessage({ id: id, action: 'open' }); } catch (e) {}
}

// Real, live-filtering search state - each skin's own topbar field was static decorative text
// until now (confirmed live: no oninput handler existed anywhere), matching neither the mockups'
// own intent nor a usable search field. QUERY/ALL_GAMES/META are
// module state so a render can be triggered from a plain oninput handler without threading
// arguments through every one of the ten design_* functions.
let ALL_GAMES = [];
let META = { user: 'Player', theme: 'light' };
let CURRENT_SKIN = 'luxury';
let QUERY = '';

function doRender() {
  const stage = document.getElementById('stage');
  const build = DESIGNS[CURRENT_SKIN] || DESIGNS.luxury;
  const q = QUERY.trim().toLowerCase();
  const filtered = q ? ALL_GAMES.filter(g => (g.title || '').toLowerCase().includes(q)) : ALL_GAMES;

  // Re-rendering replaces the whole stage, including the search field itself - without restoring
  // focus/cursor position afterward, every single keystroke would kick focus out of the field,
  // making it unusable for typing more than one character at a time.
  const activeWasSearch = document.activeElement && document.activeElement.id === 'search-input';
  const selStart = activeWasSearch ? document.activeElement.selectionStart : null;
  const selEnd = activeWasSearch ? document.activeElement.selectionEnd : null;

  stage.innerHTML = build(filtered, META);

  if (activeWasSearch) {
    const input = document.getElementById('search-input');
    if (input) {
      input.focus();
      try { input.setSelectionRange(selStart, selEnd); } catch (e) {}
    }
  }
}

function handleSearchInput(value) {
  QUERY = value;
  doRender();
}

// Every card in every design below carries data-id + onclick="postClick('...')" - a single,
// consistent bridge point no matter which skin's markup wraps it.
const click = (id) => `data-id="${esc(id)}" onclick="postClick('${id}')"`;

// A card's top-left corner badge - "Custom" for a manually-imported game, "Mac" for one found in
// the real, separate macOS Steam client's own library (never both at once, so this is a plain
// either/or). `customLabel` lets a skin keep its own existing capitalization convention (Pixel's
// real CSS badge reads "MOD", not "Custom") without a second, separate badge helper per skin.
const badge = (gm, customLabel) => {
  if (gm.custom) return `<span class="badge">${customLabel}</span>`;
  if (gm.mac) {
    const isAllCaps = customLabel === customLabel.toUpperCase();
    return `<span class="badge badge-mac">${isAllCaps ? 'MAC' : 'Mac'}</span>`;
  }
  if (gm.windows) {
    const isAllCaps = customLabel === customLabel.toUpperCase();
    return `<span class="badge badge-windows">${isAllCaps ? 'WINDOWS' : 'Windows'}</span>`;
  }
  return '';
};

// Each skin's own real .card markup, factored out from its full design_* page so a *grid-shaped
// region embedded inside a native SwiftUI layout* (Steam-style's poster grid, Spotlight's own
// grid section) can render the exact same cards Grid itself does - not a second approximation of
// them - without also pulling in that skin's topbar/h1. design_* below call these same functions,
// so there is exactly one place each skin's card markup is written.
const CARDS = {
  luxury: (games) => games.map(gm => `
    <div class="card" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 45, 135)}">
        ${badge(gm, 'Custom')}
      </div>
      <div class="body">
        <p class="title">${esc(gm.title)}</p>
        <p class="genre">${esc(gm.genre)}</p>
        <p class="desc">${esc(gm.desc)}</p>
        ${gm.running ? '<div class="run"><span class="dot"></span>Running</div>' : '<button class="cta">View Details</button>'}
      </div>
    </div>`).join(''),

  brutalist: (games) => games.map(gm => `
    <div class="card" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 80, 60)}">${badge(gm, 'Custom')}</div>
      <div class="body">
        <p class="title">${esc(gm.title)}</p>
        <span class="genre">${esc(gm.genre)}</span>
        <p class="desc">${esc(gm.desc)}</p>
        ${gm.running ? '<button class="cta run">● Running</button>' : '<button class="cta">Launch →</button>'}
      </div>
    </div>`).join(''),

  cyber: (games) => games.map(gm => `
    <div class="card" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 70, 140)}">${badge(gm, 'CUSTOM')}</div>
      <div class="body">
        <p class="title">${esc(gm.title)}</p>
        <p class="genre">${esc(gm.genre)}</p>
        <p class="desc">${esc(gm.desc)}</p>
        ${gm.running ? '<button class="cta run">● RUNNING</button>' : '<button class="cta">LAUNCH ▸</button>'}
      </div>
    </div>`).join(''),

  soft: (games) => games.map(gm => `
    <div class="card" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 25, 100)}">${badge(gm, 'Custom')}</div>
      <p class="title">${esc(gm.title)}</p>
      <p class="genre">${esc(gm.genre)}</p>
      <p class="desc">${esc(gm.desc)}</p>
      ${gm.running ? '<button class="cta run">● Running</button>' : '<button class="cta">Launch</button>'}
    </div>`).join(''),

  pixel: (games) => games.map(gm => `
    <div class="card" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 90, 100)}">${badge(gm, 'MOD')}</div>
      <div class="body">
        <p class="title">${esc(gm.title)}</p>
        <p class="genre">${esc(gm.genre)}</p>
        <p class="desc">${esc(gm.desc)}</p>
        ${gm.running ? '<button class="cta run">■ LIVE</button>' : '<button class="cta">START ▶</button>'}
      </div>
    </div>`).join(''),
};

/* ================= 1. Luxury ================= */
function design_luxury(games, meta) {
  return `
    <div class="lux">
      <div class="topbar">
        <div class="spacer"></div>
        <input id="search-input" class="search" type="text" placeholder="Search your games" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)">
      </div>
      <main>
        <h1>Your Library</h1>
        <p class="kicker">Installed and ready to play</p>
        <div class="grid">${CARDS.luxury(games)}</div>
      </main>
    </div>`;
}

/* ================= 3. Brutalist ================= */
function design_brutal(games, meta) {
  return `
    <div class="brut">
      <div class="topbar"><div class="who">PLAYDOCK</div><input id="search-input" class="search" type="text" placeholder="SEARCH YOUR GAMES_" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)"></div>
      <main><h1>Library</h1><div class="grid">${CARDS.brutalist(games)}</div></main>
    </div>`;
}

/* ================= 4. Terminal ================= */
function design_cyber(games, meta) {
  const runningCount = games.filter(g => g.running).length;
  const customCount = games.filter(g => g.custom).length;
  // A real status line instead of invented "connection secure" flavor text - the actual counts a
  // library owner would want at a glance, not stock hacker-movie dialogue.
  const kicker = runningCount > 0
    ? `${runningCount} running now`
    : `${games.length} games${customCount ? ` · ${customCount} custom` : ''}`;
  return `
    <div class="cyber">
      <div class="topbar"><span class="who">PLAY//DOCK</span><div class="spacer"></div><input id="search-input" class="search" type="text" placeholder="&gt; search_" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)"></div>
      <main><h1>LIBRARY.SYS</h1><p class="kicker">${esc(kicker)}</p><div class="grid">${CARDS.cyber(games)}</div></main>
    </div>`;
}

/* ================= 5. Soft ================= */
function design_neu(games, meta) {
  return `
    <div class="neu">
      <div class="topbar"><div class="spacer"></div><input id="search-input" class="search" type="text" placeholder="Search your games" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)"></div>
      <main><h1>Your Library</h1><div class="grid">${CARDS.soft(games)}</div></main>
    </div>`;
}

/* ================= 6. Retro pixel / arcade ================= */
function design_pixel(games, meta) {
  return `
    <div class="pix">
      <div class="topbar"><span class="who">PLAYDOCK</span><div class="spacer"></div><input id="search-input" class="search" type="text" placeholder="FIND GAME_" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)"></div>
      <main><h1>SELECT GAME</h1><div class="grid">${CARDS.pixel(games)}</div></main>
      <div class="prompt">PRESS A TO SELECT</div>
    </div>`;
}

/* ================= 8. Minimal list ================= */
function design_list(games, meta) {
  const rows = games.map(gm => `
    <div class="row" ${click(gm.id)}>
      <div class="art" style="${artStyle(gm, 25, 90)}"></div>
      <div class="title">${esc(gm.title)}${badge(gm, 'CUSTOM')}</div>
      <div class="genre">${esc(gm.genre)}</div>
      <div class="num">${esc(gm.size || '')}</div>
      <div class="num">${esc(gm.hours || '')}</div>
      <div class="status">${gm.running ? '<span class="run-pill">● Running</span>' : '<button class="launch">Launch →</button>'}</div>
    </div>`).join('');
  return `
    <div class="lst">
      <div class="topbar"><span class="who">Playdock</span><div class="spacer"></div><input id="search-input" class="search" type="text" placeholder="Search" value="${esc(QUERY)}" oninput="handleSearchInput(this.value)"></div>
      <main>
        <h1>Library</h1>
        <p class="sub">Sorted by name</p>
        <div class="head"><span></span><span>Title</span><span>Genre</span><span style="text-align:right">Size</span><span style="text-align:right">Played</span><span></span></div>
        ${rows}
      </main>
    </div>`;
}

const DESIGNS = {
  luxury: design_luxury,
  brutalist: design_brutal,
  cyber: design_cyber,
  soft: design_neu,
  pixel: design_pixel,
  minimal: design_list,
};

// The CSS scoping class each skin's own markup uses - not the same string as its DESIGNS/CARDS
// key (skins.css was authored with these shorter names before the skins themselves were renamed
// to plainer ones).
const SKIN_CLASS = {
  luxury: 'lux', brutalist: 'brut', cyber: 'cyber', soft: 'neu', pixel: 'pix',
};

// Called from Swift via evaluateJavaScript after every load and whenever the underlying data or
// active skin/theme changes - a full re-render each time is simple, correct, and cheap enough for a
// library of even a few hundred games. QUERY is deliberately *not* reset here - a fresh push of
// data from Swift (running-state changed, art finished loading) shouldn't blow away whatever the
// user is mid-typing into the search field.
window.PlaydockRender = function (skinKey, gamesJSON, metaJSON) {
  try { ALL_GAMES = JSON.parse(gamesJSON); } catch (e) { ALL_GAMES = []; }
  try { META = JSON.parse(metaJSON); } catch (e) { META = { user: 'Player', theme: 'light' }; }
  CURRENT_SKIN = skinKey;
  document.documentElement.setAttribute('data-stage-theme', META.theme === 'dark' ? 'dark' : 'light');
  document.documentElement.setAttribute('data-hide-badges', META.hideBadges ? 'true' : 'false');
  doRender();
};

// A grid-shaped fragment only - real card markup (CARDS above), wrapped in just enough of the
// skin's own class scoping for its card CSS to apply, with no topbar/h1/kicker. Used by
// SkinWebGridFragmentView to embed a real, skin-accurate card grid inside a native SwiftUI layout
// (Steam-style's poster grid, Spotlight's own grid section) - those are structurally the exact
// same shape Grid itself is (a wrapping grid of cards), so this reuses the real thing rather than
// a second hand-ported approximation of it. Minimal has no `.grid`/`.card` markup at all in the
// real mockup (it's genuinely list-shaped even in Grid mode), so it isn't in CARDS and callers
// should keep using a native list for it.
window.PlaydockRenderGridFragment = function (skinKey, gamesJSON, themeJSON) {
  const stage = document.getElementById('stage');
  let games = [];
  try { games = JSON.parse(gamesJSON); } catch (e) { games = []; }
  let theme = 'light';
  let hideBadges = false;
  try {
    const parsedTheme = JSON.parse(themeJSON);
    theme = parsedTheme.theme === 'dark' ? 'dark' : 'light';
    hideBadges = !!parsedTheme.hideBadges;
  } catch (e) {}
  document.documentElement.setAttribute('data-stage-theme', theme);
  document.documentElement.setAttribute('data-hide-badges', hideBadges ? 'true' : 'false');
  const cardsFn = CARDS[skinKey] || CARDS.luxury;
  const skinClass = SKIN_CLASS[skinKey] || SKIN_CLASS.luxury;
  stage.innerHTML = `<div class="${skinClass} grid-fragment"><div class="grid">${cardsFn(games)}</div></div>`;
};

// A controller's D-pad has no native concept of "hovering" a card the way a mouse does, and this
// page has no idea a controller even exists - Swift is the one tracking which index is focused
// (ControllerObserver/DashboardFocusTarget), so it just tells the page which card that is on every
// change. Cards render in the exact same order `games` was passed in (CARDS.* maps over it
// in order), so index N here really is entry N's own card, no separate id-matching needed. Called
// with `null`/undefined to clear focus entirely (controller disconnected, or focus moved to a
// native control outside the grid).
window.PlaydockSetFocus = function (id) {
  const cards = document.querySelectorAll('#stage .card');
  cards.forEach((el) => {
    if (id != null && el.dataset.id === id) {
      el.classList.add('controller-focus');
      el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    } else {
      el.classList.remove('controller-focus');
    }
  });
};
