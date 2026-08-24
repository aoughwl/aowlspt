## aowlspt/uihub — the fallback settings UI.
##
## The problem this solves. The NATIVE in-game F12 settings screen (built on the
## D3D11 overlay, `abi/aowlspt_overlay.h`) has taken 20+ hours and still is not
## finished, and a player or mod author should not have to wait on it to see or
## change a setting. Every setting already lives behind ordinary HTTP —
## `GET /aowlspt/settings/index`, `GET/POST /aowlspt/settings/<guid>` — served
## by `aowlspt/settings` (see that module) and aggregated by `mods/settingshub`.
## This mod adds no new settings logic of its own; it is **one HTML page that
## calls those same routes from an ordinary web browser**, so it is a fallback
## in the strongest sense: it does not touch the overlay, the D3D11 present
## hook, or any client-side rendering at all. Point any browser at
## `https://127.0.0.1:443/aowlspt/ui/page/settings` (self-signed cert; accept
## the browser warning) and it works whether or not the game is even running,
## as long as the backend is up.
##
## The full public surface — routes, JSON shapes, how a third party builds
## their own page against the same endpoints — is documented in
## `docs/UI-API.md`; that document is the contract, this mod is one client of
## it, and it is written to be read alongside this file.
##
## Why a browser page and not more overlay C code: the overlay's own render
## path (`aowl_ov_read_panel` et al.) is hand-written per-shape C reading a
## fixed schema (the mods panel) — extending it to a generic settings renderer
## would mean a second implementation of "how to draw a Setting.kind" beside
## the native F12 screen's, which is exactly the divergent logic the brief
## rules out. A browser already has a JSON parser, a DOM and an input widget
## for every `SettingType`; this page is ~150 lines of vanilla JS because it
## does not have to reimplement any of that.
##
## Wire note (see `docs/UI-API.md` and fact #123): the backend deflates every
## response by default and never sends a `Content-Encoding` header, which is
## fine for the overlay's own C worker (it always inflates) but unreachable
## from browser JS — the Fetch spec forbids scripts from ever setting
## `Accept-Encoding`. So every fetch from this page's JS appends `?ident=1`,
## a query-string spelling of the same "send it uncompressed" request the
## header already supports (see `backend/aowlbackend.nim`, `parseHead`) that a
## browser is allowed to send. The JSON shape returned is byte-for-byte the
## same either way — only the wire transport differs.

import aowlspt
import aowlspt/server as sv

const
  ModGuid = "aowl.uihub"
  ModName = "Fallback Settings UI"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

  PageRoute = "/aowlspt/ui/page/settings"

## The whole page: markup, styling and the JS client for the settings API, as
## one self-contained document with no external request but the ones it makes
## back to this same backend. Kept as a single string so the mod ships as one
## DLL, the same reasoning `mods/settingshub` gives for embedding its catalogue
## at build time.
const PageHtml = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>aowlspt settings (fallback)</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: -apple-system, Segoe UI, sans-serif; background:#141414; color:#ddd; margin:0; display:flex; height:100vh; }
  nav { width:220px; overflow-y:auto; background:#1c1c1c; border-right:1px solid #2c2c2c; padding:8px; box-sizing:border-box; }
  nav div.mod { padding:8px 10px; border-radius:6px; cursor:pointer; margin-bottom:2px; }
  nav div.mod:hover { background:#2a2a2a; }
  nav div.mod.active { background:#3a5a8c; color:#fff; }
  main { flex:1; overflow-y:auto; padding:20px 28px; }
  h1 { font-size:16px; color:#9c9c9c; font-weight:600; margin:0 0 18px; }
  .cat { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:#7d99c9; margin:22px 0 8px; }
  .row { display:flex; align-items:center; justify-content:space-between; padding:8px 0; border-bottom:1px solid #232323; gap:16px; }
  .row .label { flex:1; }
  .row .label small { display:block; color:#888; font-weight:400; margin-top:2px; }
  .row.dim { opacity:.5; }
  .row input[type=text], .row select { background:#222; color:#ddd; border:1px solid #333; border-radius:4px; padding:5px 8px; min-width:140px; }
  .row input[type=number] { background:#222; color:#ddd; border:1px solid #333; border-radius:4px; padding:5px 8px; width:90px; }
  .row input[type=checkbox] { width:18px; height:18px; }
  .saved { color:#6fbf6f; font-size:11px; margin-left:8px; opacity:0; transition:opacity .2s; }
  .saved.show { opacity:1; }
  #status { color:#888; padding:10px 0; }
</style>
</head>
<body>
<nav id="nav"><div id="status">loading&hellip;</div></nav>
<main>
  <h1 id="title">aowlspt &mdash; fallback settings UI</h1>
  <div id="body">Pick a mod on the left. This page reads and writes the exact
  same <code>/aowlspt/settings/&lt;guid&gt;</code> endpoint the native F12
  screen uses &mdash; see <code>docs/UI-API.md</code> for the surface.</div>
</main>
<script>
// One source of truth: the same GET/POST JSON routes the native F12 overlay
// panel calls. `?ident=1` only changes the wire transport (see the mod's
// docstring); the JSON shape below is exactly docs/UI-API.md.
async function apiGet(path) {
  const sep = path.indexOf('?') >= 0 ? '&' : '?';
  const r = await fetch(path + sep + 'ident=1', {cache: 'no-store'});
  return r.json();
}
async function apiPost(path, body) {
  const sep = path.indexOf('?') >= 0 ? '&' : '?';
  const r = await fetch(path + sep + 'ident=1', {
    method: 'POST', cache: 'no-store',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body)
  });
  return r.json();
}

let currentGuid = null;

function inputFor(row, onSave) {
  const wrap = document.createElement('span');
  let el;
  if (row.type === 'bool') {
    el = document.createElement('input');
    el.type = 'checkbox';
    el.checked = !!row.value;
    el.onchange = () => onSave(el.checked);
  } else if (row.type === 'enum') {
    el = document.createElement('select');
    (row.options || []).forEach(o => {
      const opt = document.createElement('option');
      opt.value = o; opt.textContent = o;
      if (JSON.stringify(o) === JSON.stringify(row.value)) opt.selected = true;
      el.appendChild(opt);
    });
    el.onchange = () => onSave(el.value);
  } else if (row.type === 'int' || row.type === 'float') {
    el = document.createElement('input');
    el.type = 'number';
    el.value = row.value;
    if (row.min !== undefined) el.min = row.min;
    if (row.max !== undefined) el.max = row.max;
    if (row.step !== undefined) el.step = row.step;
    el.onchange = () => onSave(row.type === 'int' ? parseInt(el.value, 10) : parseFloat(el.value));
  } else {
    // string / keybind
    el = document.createElement('input');
    el.type = 'text';
    el.value = row.value;
    el.onchange = () => onSave(el.value);
  }
  wrap.appendChild(el);
  return wrap;
}

async function loadPage(guid) {
  currentGuid = guid;
  document.querySelectorAll('#nav .mod').forEach(d => d.classList.toggle('active', d.dataset.guid === guid));
  const rows = await apiGet('/aowlspt/settings/' + encodeURIComponent(guid));
  const body = document.getElementById('body');
  body.innerHTML = '';
  document.getElementById('title').textContent = guid;
  let lastCat = null;
  (Array.isArray(rows) ? rows : []).forEach(row => {
    if ((row.category || '') !== lastCat) {
      lastCat = row.category || '';
      if (lastCat) {
        const h = document.createElement('div');
        h.className = 'cat'; h.textContent = lastCat;
        body.appendChild(h);
      }
    }
    const r = document.createElement('div');
    r.className = 'row' + (row.implemented === false ? ' dim' : '');
    const lab = document.createElement('div');
    lab.className = 'label';
    lab.innerHTML = '<div>' + row.label + '</div>' +
      (row.description ? '<small>' + row.description + '</small>' : '');
    r.appendChild(lab);
    const saved = document.createElement('span');
    saved.className = 'saved'; saved.textContent = 'saved';
    const ctl = inputFor(row, async (val) => {
      const reply = await apiPost('/aowlspt/settings/' + encodeURIComponent(guid),
        {key: row.key, value: val});
      saved.classList.add('show');
      setTimeout(() => saved.classList.remove('show'), 900);
      // Re-render from the reply so a value the backend clamped or rejected
      // shows what actually landed, not what was typed -- the single-source-
      // of-truth rule applies to a rejected write as much as an accepted one.
      if (Array.isArray(reply)) loadPage(guid);
    });
    ctl.appendChild(saved);
    r.appendChild(ctl);
    body.appendChild(r);
  });
  if (!rows || !rows.length) {
    body.innerHTML = '<p>No declared settings for this mod, or the schema came back empty.</p>';
  }
}

async function init() {
  const nav = document.getElementById('nav');
  try {
    const idx = await apiGet('/aowlspt/settings/index');
    nav.innerHTML = '';
    const mods = (idx && idx.mods) || [];
    if (!mods.length) {
      nav.innerHTML = '<div id="status">No mod has declared settings yet.</div>';
      return;
    }
    mods.forEach(m => {
      const d = document.createElement('div');
      d.className = 'mod';
      d.dataset.guid = m.guid;
      d.textContent = m.name + ' (' + m.count + ')';
      d.onclick = () => loadPage(m.guid);
      nav.appendChild(d);
    });
    loadPage(mods[0].guid);
  } catch (e) {
    nav.innerHTML = '<div id="status">Could not reach the backend: ' + e + '</div>';
  }
}
init();
</script>
</body>
</html>
"""

proc onPage(url, body, session: string): string =
  result = PageHtml

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server-side page; nothing to do on this side"
    return Ok
  if serve(PageRoute, onPage) != Ok:
    warn "could not register " & PageRoute
  success ModName & " " & ModVersion & " serving " & PageRoute &
          " -- the same /aowlspt/settings/* routes the native F12 screen uses"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer},
  onLoad = onLoad)
