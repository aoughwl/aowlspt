## aowlspt/uihub — the settings UI, and the client library it is built out of.
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
## **Two routes, one implementation.** Everything this page knows how to do —
## call the API, filter rows, group them, draw a control for a `type` — lives in
## a library served at `GET /aowlspt/ui/lib/settings.js` as `window.AowlSettings`.
## The page at `/aowlspt/ui/page/settings` is a thin shell that loads that same
## URL with a `<script src>`; it has no private copy. That is the whole answer to
## "expose this logic so people can make their own UIs": a third-party page adds
## one script tag and gets `AowlSettings.mount(el)` for the finished screen, or
## `getSchema`/`setValue`/`controlFor`/`matches`/`groupRows` to build its own —
## against the identical code path the shipped page runs, so a third-party UI
## cannot drift from it.
##
## **Scale.** The design target is HUNDREDS of settings per mod (`mods/tarkov`
## is heading there) and thousands of choices in one control (item ids). So the
## library carries: a search that matches key/label/description/category across
## one mod or every mod at once; collapsible category → subcategory sections
## with a sidebar and a deep-linkable hash; incremental rendering that puts a
## bounded number of rows in the DOM and appends the rest as you scroll; a
## searchable typeahead for `type:"select"` (and for any `enum` with more
## options than a dropdown should hold), able to fetch its choices on demand
## from the row's `optionsUrl`; and a slider-plus-number pair for any numeric
## row whose schema declared a range.
##
## None of that changes a single route or a single JSON shape. The `Setting`
## object gained three OPTIONAL fields (`subcategory`, `optionLabels`,
## `optionsUrl`) and the `type` vocabulary gained `select`, all emitted only
## when a mod asks for them — a renderer that has never heard of any of it draws
## exactly what it drew before. The full public surface is `docs/UI-API.md`.
##
## Why a browser page and not more overlay C code: the overlay's own render
## path (`aowl_ov_read_panel` et al.) is hand-written per-shape C reading a
## fixed schema (the mods panel) — extending it to a generic settings renderer
## would mean a second implementation of "how to draw a Setting.kind" beside
## the native F12 screen's, which is exactly the divergent logic the brief
## rules out. A browser already has a JSON parser, a DOM and an input widget
## for every `SettingType`.
##
## Wire note (see `docs/UI-API.md` and fact #123): the backend deflates every
## response by default and never sends a `Content-Encoding` header, which is
## fine for the overlay's own C worker (it always inflates) but unreachable
## from browser JS — the Fetch spec forbids scripts from ever setting
## `Accept-Encoding`. So every fetch from this page's JS appends `?ident=1`,
## a query-string spelling of the same "send it uncompressed" request the
## header already supports (see `backend/aowlbackend.nim`, `parseHead`) that a
## browser is allowed to send. The JSON shape returned is byte-for-byte the
## same either way — only the wire transport differs. The library route is
## served uncompressed and as `text/javascript` for the same reason, by the
## `/aowlspt/ui/lib/` branch in `backend/aowlbackend.nim` — a browser refuses
## to execute a script labelled `application/json`.

import aowlspt
import aowlspt/server as sv
import aowlspt/settings

const
  ModGuid = "aowl.uihub"
  ModName = "Browser Settings Page"
    ## Was "Fallback Settings UI". Two branches renamed this at once:
    ## feat-internal-mods chose "Interface", feat-overlay-settings-ui chose
    ## "Browser Settings Page". The latter wins because it is the name carried
    ## by the deploy.json marker and two test fixtures, and because it says
    ## what the page IS rather than naming a generic.
    ##
    ## The MOD is infrastructure and is marked `internal` in the registry, so
    ## it no longer appears on the mod list -- but it declares one genuine
    ## player row (the F12 launch hint), so it still has a settings page, and
    ## that page needs a name a player can read.
  ModAuthor = "savannt"
  ModVersion = "2.0.0"

  PageRoute = "/aowlspt/ui/page/settings"
  LibRoute = "/aowlspt/ui/lib/settings.js"

## The client library — the ONLY place this repo implements "talk to the
## settings API and draw it". Served verbatim at `LibRoute`, loaded by the page
## below, and equally loadable by anybody else's page. Kept as a source string
## so the mod ships as one DLL with no file beside it, the same reasoning
## `mods/settingshub` gives for embedding its catalogue at build time.
const LibJs = """/* aowlspt settings client -- window.AowlSettings.
 * Served at /aowlspt/ui/lib/settings.js by mods/uihub. The shipped page at
 * /aowlspt/ui/page/settings is nothing but a shell around mount(); a third
 * party page can do the same, or use the lower-level pieces. Contract:
 * docs/UI-API.md. No dependencies, no build step, no framework.
 */
(function (global) {
'use strict';

/* ---- transport ------------------------------------------------------ */
/* `ident=1` asks the backend for an uncompressed response. It changes the
 * bytes on the wire and nothing about the JSON. Browser JS is not permitted
 * to send Accept-Encoding, which is why this exists at all. */
function withIdent(path) {
  return path + (path.indexOf('?') >= 0 ? '&' : '?') + 'ident=1';
}
async function apiGet(path) {
  var r = await fetch(withIdent(path), {cache: 'no-store'});
  return r.json();
}
async function apiPost(path, body) {
  var r = await fetch(withIdent(path), {
    method: 'POST', cache: 'no-store',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body)
  });
  return r.json();
}

/* A POST reply is the bare [{Setting}...] array on success, or
 * {"err":"...","rows":[...]} when the persist failed. This is the one place
 * that tells them apart, so a rejected write cannot look like an accepted
 * one. Never weaken these to a truthiness check. */
function replyOk(reply)   { return Array.isArray(reply); }
function replyRows(reply) { return Array.isArray(reply) ? reply : (reply && reply.rows) || []; }
function replyErr(reply)  { return (reply && !Array.isArray(reply) && reply.err) || null; }

var S = '/aowlspt/settings/';
function listMods()  { return apiGet(S + 'index').then(function (i) { return (i && i.mods) || []; }); }
function getSchema(guid) { return apiGet(S + encodeURIComponent(guid)).then(replyRows); }
function setValue(guid, key, value) { return apiPost(S + encodeURIComponent(guid), {key: key, value: value}); }
function resetKey(guid, key) { return apiPost(S + encodeURIComponent(guid) + '/reset', {key: key}); }
function resetAll(guid) { return apiPost(S + encodeURIComponent(guid) + '/reset', {}); }

/* ---- searching and grouping ----------------------------------------- */

function haystack(row) {
  if (row.__hay === undefined) {
    /* `path` is included because it is now what the HEADINGS are drawn from
     * (see `groupOf`): searching for a section name the user can see on screen
     * and getting nothing back is the same defect as a control that does
     * nothing. `category`/`subcategory` stay in as well -- they are still what
     * an older server sends. */
    row.__hay = [row.key, row.label, row.description, row.category,
                 row.subcategory, (row.path || []).join(' ')]
                .filter(Boolean).join(' ').toLowerCase();
  }
  return row.__hay;
}
/* THE keybind predicate. One place, asked by the row filter, the mod-list
 * filter and the verdict counters alike, so those three cannot disagree.
 *
 * It reads the DECLARED facet (`aowl/src/aowlspt/settings.nim`, `isKeybind`) and
 * never the key's name. Name-matching is wrong in both directions on this
 * repo's own data: `mods/loadammoanim`'s `hijackKey` is a BUNDLE NAME and would
 * be shown, while `mods/debug`'s `overlayToggleKey` (an int VK code) and the
 * `hotkeys` gates in `mods/maps`/`mods/admin` would be hidden -- and hiding a
 * gate leaves a key on screen that provably cannot fire. */
function isKeybindRow(row) {
  return row.keybind === true || row.type === 'keybind';
}
/* Does this server emit the facet at all? A row from a backend older than the
 * facet has no `keybind` field, and reading that absence as `false` would empty
 * the filter and look broken. Absence is reported, never silently filtered. */
function declaresKeybindFacet(row) {
  return row && row.keybind !== undefined;
}

/* Every whitespace-separated word must appear somewhere in the row's text.
 * AND, not OR, because with hundreds of rows an OR search returns the whole
 * list and reads as "search is broken". */
function matches(row, query) {
  var t = (query || '').trim().toLowerCase();
  if (!t) return true;
  var h = haystack(row);
  return t.split(/\s+/).every(function (w) { return h.indexOf(w) >= 0; });
}

/* [{name, subs:[{name, rows:[row...]}]}] in DECLARATION order -- a mod author
 * orders their schema deliberately and re-sorting it alphabetically throws
 * that away. Rows with no category land in one leading unnamed group. */
/* `path` is the schema's ORDERED group path (aowl/src/aowlspt/settings.nim,
 * `settingPath`). It was being emitted and ignored here: the grouping keyed on
 * the raw `category` STRING, so a mod that declared "Loot/Global",
 * "Loot/Containers", "Loot/Item mix" got EIGHT sibling top-level sections whose
 * headers all read "Loot/<something>", instead of one Loot screen with eight
 * sub-headers. That is the "28-row flat list" complaint one level up: the
 * sections were declared and the renderer threw the structure away.
 *
 * The section model here is genuinely two-level, so depth beyond two is folded
 * into the sub-header ("Item mix > Category weights") rather than silently
 * dropped -- a third level that vanished would put rows under a heading that
 * does not describe them.
 *
 * `path` absent -> the old category/subcategory reading, unchanged. An older
 * server that emits no `path` renders exactly as it does today. */
function groupOf(row) {
  var p = row.path;
  if (!p || !p.length) return {c: row.category || '', sc: row.subcategory || ''};
  if (p.length === 1) return {c: p[0], sc: ''};
  return {c: p[0], sc: p.slice(1).join(' > ')};
}
function groupRows(rows) {
  var cats = [], byCat = {};
  rows.forEach(function (row) {
    var g0 = groupOf(row), c = g0.c, sc = g0.sc;
    var g = byCat[c];
    if (!g) { g = byCat[c] = {name: c, subs: [], bySub: {}}; cats.push(g); }
    var sg = g.bySub[sc];
    if (!sg) { sg = g.bySub[sc] = {name: sc, rows: []}; g.subs.push(sg); }
    sg.rows.push(row);
  });
  return cats;
}

/* ---- controls -------------------------------------------------------- */

/* An inline <select> stops being usable somewhere around here; past it a row
 * gets the typeahead even if it only declared itself an `enum`. */
var INLINE_OPTION_MAX = 24;

function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined && text !== null) e.textContent = text;
  return e;
}

/* options + optionLabels (parallel, optional) -> [{value,label}]. */
function inlineOptions(row) {
  var opts = row.options || [], labels = row.optionLabels || [];
  var useLabels = labels.length === opts.length;
  return opts.map(function (o, i) {
    return {value: o, label: useLabels ? labels[i] : String(o)};
  });
}
function labelForValue(row, value) {
  var v = value === undefined || value === null ? '' : String(value);
  var inline = inlineOptions(row);
  for (var i = 0; i < inline.length; i++) {
    if (String(inline[i].value) === v) return inline[i].label;
  }
  return v;
}

/* A searchable select. Draws the CURRENT value as text, filters as you type,
 * and shows at most TYPEAHEAD_MAX matches -- the point of this control is that
 * the option set may be in the thousands, so it must never build a DOM node
 * per option. Choices come from the row's inline `options` and, when the row
 * declares an `optionsUrl`, from that route as the user types:
 *   GET <optionsUrl>?q=<term>&limit=<n> -> {"options":[{value,label}...]}
 * Committing requires PICKING a listed choice (click, Enter, or typing text
 * that exactly matches one). Free text is refused and the box reverts, so a
 * typo can never be persisted as an item id. */
var TYPEAHEAD_MAX = 60;

function typeahead(row, onSave) {
  var wrap = el('span', 'ta');
  var input = el('input', 'ta-input');
  input.type = 'text';
  input.placeholder = 'search' + (row.options && row.options.length
                                  ? ' ' + row.options.length + ' choices' : '');
  var committed = row.value === undefined || row.value === null ? '' : String(row.value);
  input.value = labelForValue(row, committed);
  var list = el('div', 'ta-list');
  list.style.display = 'none';
  var note = el('div', 'ta-note');
  wrap.appendChild(input);
  wrap.appendChild(list);
  wrap.appendChild(note);

  var shown = [], cursor = -1, seq = 0, timer = null;

  function close() { list.style.display = 'none'; cursor = -1; }
  function revert() { input.value = labelForValue(row, committed); }

  function draw(items, truncated) {
    list.innerHTML = '';
    shown = items;
    if (!items.length) {
      list.appendChild(el('div', 'ta-empty', 'no match'));
    } else {
      items.forEach(function (o, i) {
        var d = el('div', 'ta-opt', o.label);
        if (o.label !== String(o.value)) d.appendChild(el('small', null, String(o.value)));
        d.onmousedown = function (ev) { ev.preventDefault(); commit(o); };
        d.onmouseenter = function () { setCursor(i); };
        list.appendChild(d);
      });
      if (truncated) {
        list.appendChild(el('div', 'ta-empty',
          'showing first ' + items.length + ' -- keep typing to narrow'));
      }
    }
    list.style.display = '';
  }
  function setCursor(i) {
    cursor = i;
    Array.prototype.forEach.call(list.querySelectorAll('.ta-opt'), function (d, j) {
      d.classList.toggle('on', j === i);
    });
  }
  function commit(o) {
    committed = String(o.value);
    input.value = o.label;
    close();
    onSave(o.value);
  }

  async function search(term) {
    var mine = ++seq;
    var t = term.trim().toLowerCase();
    var out = [], truncated = false;
    var inline = inlineOptions(row);
    for (var i = 0; i < inline.length; i++) {
      var o = inline[i];
      if (!t || o.label.toLowerCase().indexOf(t) >= 0 ||
          String(o.value).toLowerCase().indexOf(t) >= 0) {
        if (out.length >= TYPEAHEAD_MAX) { truncated = true; break; }
        out.push(o);
      }
    }
    if (row.optionsUrl) {
      note.textContent = 'searching' + String.fromCharCode(0x2026);
      try {
        var sep = row.optionsUrl.indexOf('?') >= 0 ? '&' : '?';
        var res = await apiGet(row.optionsUrl + sep + 'q=' + encodeURIComponent(term) +
                               '&limit=' + TYPEAHEAD_MAX);
        if (mine !== seq) return;               /* a newer keystroke won */
        note.textContent = '';
        var remote = (res && res.options) || [];
        var seen = {};
        out.forEach(function (o) { seen[String(o.value)] = 1; });
        remote.forEach(function (o) {
          var v = String(o.value === undefined ? o : o.value);
          if (seen[v]) return;
          seen[v] = 1;
          if (out.length >= TYPEAHEAD_MAX) { truncated = true; return; }
          out.push({value: v, label: o.label === undefined ? v : String(o.label)});
        });
      } catch (e) {
        if (mine !== seq) return;
        /* Say so. A typeahead that silently shows only the inline options
         * after its remote source failed is the "declines quietly" shape. */
        note.textContent = 'option source unreachable: ' + e;
      }
    }
    if (mine !== seq) return;
    draw(out, truncated);
  }

  input.onfocus = function () { search(''); };
  input.oninput = function () {
    if (timer) clearTimeout(timer);
    var v = input.value;
    timer = setTimeout(function () { search(v); }, 140);
  };
  input.onkeydown = function (ev) {
    if (ev.key === 'ArrowDown') { ev.preventDefault(); setCursor(Math.min(cursor + 1, shown.length - 1)); }
    else if (ev.key === 'ArrowUp') { ev.preventDefault(); setCursor(Math.max(cursor - 1, 0)); }
    else if (ev.key === 'Enter') {
      ev.preventDefault();
      if (cursor >= 0 && shown[cursor]) commit(shown[cursor]);
      else {
        var t = input.value.trim().toLowerCase();
        var hit = shown.filter(function (o) {
          return o.label.toLowerCase() === t || String(o.value).toLowerCase() === t;
        })[0];
        if (hit) commit(hit); else revert();
      }
    } else if (ev.key === 'Escape') { revert(); close(); input.blur(); }
  };
  input.onblur = function () {
    setTimeout(function () { close(); revert(); }, 120);
  };
  return wrap;
}

/* Numeric: a slider whenever the schema declared a range, plus a typed box,
 * both bound to the same value. Without a range there is only the box --
 * inventing min/max would be a lie about what the mod declared. */
function numeric(row, onSave) {
  var wrap = el('span', 'num');
  var isInt = row.type === 'int';
  var parse = function (s) { return isInt ? parseInt(s, 10) : parseFloat(s); };
  var box = el('input', 'num-box');
  box.type = 'number';
  box.value = row.value;
  var hasRange = row.min !== undefined && row.max !== undefined && row.max > row.min;
  var slider = null;
  if (hasRange) {
    slider = el('input', 'num-slider');
    slider.type = 'range';
    slider.min = row.min; slider.max = row.max;
    slider.step = row.step !== undefined && row.step > 0 ? row.step : (isInt ? 1 : 'any');
    slider.value = row.value;
    slider.oninput = function () { box.value = slider.value; };
    slider.onchange = function () { onSave(parse(slider.value)); };
    wrap.appendChild(slider);
  }
  if (row.min !== undefined) box.min = row.min;
  if (row.max !== undefined) box.max = row.max;
  if (row.step !== undefined && row.step > 0) box.step = row.step;
  box.onchange = function () {
    if (slider) slider.value = box.value;
    onSave(parse(box.value));
  };
  wrap.appendChild(box);
  return wrap;
}

/* ---- the colour picker ------------------------------------------------
 *
 * ONE widget, used by every `type:"color"` row anywhere in the tree. That
 * reusability is the point: a mod declares `colorSetting(...)` and gets this,
 * rather than each overlay growing its own one-off swatch.
 *
 * The value on the wire is the shape the HOST already parses out of
 * `aowlspt-debugui.json` -- "r,g,b" or "r,g,b,a", components 0..1. Nothing
 * downstream had to learn a new format.
 *
 * ROUND-TRIP, which is the part that is easy to get quietly wrong: the floats
 * are the source of truth and hex is a LOSSY VIEW of them, never the storage.
 * Storing 0..255 ints instead would turn 0.62 into 158/255 = 0.6196... on the
 * first save -- a change the user never asked for, that looks exactly like the
 * setting failing to persist. Values are emitted at 4 decimal places, which is
 * idempotent: parse(fmt(x)) === fmt(x) for anything this widget ever writes, so
 * re-saving an untouched colour cannot drift it.
 *
 * ALPHA is preserved but never invented: a value that arrived with three
 * components is written back with three. */
function cfmt(v) {
  if (!isFinite(v)) v = 0;
  if (v < 0) v = 0; if (v > 1) v = 1;
  return String(Math.round(v * 10000) / 10000);
}
function chex2(v) {
  var n = Math.round(v * 255);
  if (n < 0) n = 0; if (n > 255) n = 255;
  var s = n.toString(16);
  return s.length < 2 ? '0' + s : s;
}
function parseColor(text) {
  /* Returns {r,g,b,a,hasA}. Anything unparseable falls back to opaque white --
   * a visible, obviously-wrong colour beats a silently black swatch that reads
   * as a legitimate choice. */
  var c = { r: 1, g: 1, b: 1, a: 1, hasA: false };
  var s = String(text === undefined || text === null ? '' : text).trim();
  /* BARE hex, no '#'. `mods/maps` has stored `colorBot` as "E6463C" since long
   * before this widget existed, and reading that down the comma path gives
   * parseFloat("E6463C") = NaN -> the white fallback, i.e. the picker would
   * open showing a colour the map is not drawing. Only an EXACT 6 or 8 hex
   * digits is taken this way: "255,0,0" still has commas, and a 3-digit "abc"
   * is left to the comma path where it reads as "fewer than three components"
   * and falls back honestly rather than being guessed at. */
  if (s.charAt(0) !== '#' && /^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(s)) s = '#' + s;
  if (s.charAt(0) === '#') {
    var h = s.slice(1);
    if (h.length === 3) h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
    if (h.length === 6 || h.length === 8) {
      var v = parseInt(h, 16);
      if (!isNaN(v)) {
        if (h.length === 8) {
          c.r = ((v >>> 24) & 255) / 255; c.g = ((v >>> 16) & 255) / 255;
          c.b = ((v >>> 8) & 255) / 255;  c.a = (v & 255) / 255; c.hasA = true;
        } else {
          c.r = ((v >>> 16) & 255) / 255; c.g = ((v >>> 8) & 255) / 255;
          c.b = (v & 255) / 255;
        }
      }
    }
    return c;
  }
  var parts = s.split(',');
  var nums = [];
  for (var i = 0; i < parts.length; i++) {
    var n = parseFloat(parts[i]);
    if (isNaN(n)) return c;
    /* Tolerate a 0..255 colour written by hand: if ANY component exceeds 1 the
     * whole tuple is read as 0..255. Per-component guessing would turn
     * "255,0,0" into "1,0,0" only for the red channel. */
    nums.push(n);
  }
  if (nums.length < 3) return c;
  var scale = 1;
  for (var j = 0; j < nums.length; j++) if (nums[j] > 1) scale = 255;
  c.r = nums[0] / scale; c.g = nums[1] / scale; c.b = nums[2] / scale;
  if (nums.length >= 4) { c.a = nums[3] / (scale === 255 ? 255 : 1); c.hasA = true; }
  return c;
}
function colorText(c, fmt) {
  /* Writes the shape the OWNING MOD's own reader parses -- `row.colorFormat`,
   * defaulted here rather than at the call sites so an older server that emits
   * no such field still gets the "r,g,b" it has always got. */
  if (fmt === 'hex' || fmt === 'hex#') {
    return (fmt === 'hex#' ? '#' : '') +
           chex2(c.r) + chex2(c.g) + chex2(c.b) + (c.hasA ? chex2(c.a) : '');
  }
  var s = cfmt(c.r) + ',' + cfmt(c.g) + ',' + cfmt(c.b);
  if (c.hasA) s += ',' + cfmt(c.a);
  return s;
}
function cssOf(c) {
  return 'rgba(' + Math.round(c.r * 255) + ',' + Math.round(c.g * 255) + ',' +
         Math.round(c.b * 255) + ',' + c.a + ')';
}
/* HSV <-> RGB, so the saturation/value field and the hue strip mean what they
 * look like they mean. */
function rgb2hsv(c) {
  var mx = Math.max(c.r, c.g, c.b), mn = Math.min(c.r, c.g, c.b), d = mx - mn;
  var h = 0;
  if (d > 0) {
    if (mx === c.r) h = ((c.g - c.b) / d + (c.g < c.b ? 6 : 0)) / 6;
    else if (mx === c.g) h = ((c.b - c.r) / d + 2) / 6;
    else h = ((c.r - c.g) / d + 4) / 6;
  }
  return { h: h, s: mx === 0 ? 0 : d / mx, v: mx };
}
function hsv2rgb(h, s, v) {
  var i = Math.floor(h * 6), f = h * 6 - i;
  var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
  switch (i % 6) {
    case 0: return { r: v, g: t, b: p };
    case 1: return { r: q, g: v, b: p };
    case 2: return { r: p, g: v, b: t };
    case 3: return { r: p, g: q, b: v };
    case 4: return { r: t, g: p, b: v };
    default: return { r: v, g: p, b: q };
  }
}
function colorpicker(row, onSave) {
  var c = parseColor(row.value);
  var cfg = row.colorFormat || 'rgb';
  /* A hex row that carries no alpha byte must never GROW one: `maps.parseRgb`
   * requires exactly six digits and returns its DEFAULT on seven or eight, so a
   * spurious alpha would silently revert the colour on the next read. The alpha
   * channel is therefore offered only where the declared value already had one,
   * which `parseColor` has already decided (`hasA`). */
  var hsv = rgb2hsv(c);
  var wrap = el('span', 'cp');
  var sw = el('button', 'cp-sw');           /* the preview, and the opener */
  sw.type = 'button';
  var pop = el('div', 'cp-pop');
  pop.style.display = 'none';

  /* Live apply while dragging, without one POST per mouse-move. The trailing
   * call is unconditional, so the value the user let go on is always the one
   * that gets persisted -- a debounce that can drop the LAST event would leave
   * the screen and the disk disagreeing. */
  var timer = null, pending = null;
  function commit(now) {
    pending = colorText(c, cfg);
    if (now) {
      if (timer) { clearTimeout(timer); timer = null; }
      onSave(pending);
      return;
    }
    if (timer) return;
    timer = setTimeout(function () { timer = null; onSave(pending); }, 60);
  }

  var field = el('div', 'cp-field');        /* saturation x value */
  var fdot = el('div', 'cp-dot');
  field.appendChild(fdot);
  var hue = el('div', 'cp-hue');
  var hdot = el('div', 'cp-hdot');
  hue.appendChild(hdot);
  var hexbox = el('input', 'cp-hex');
  hexbox.type = 'text';
  var rows = el('div', 'cp-rgba');
  var chans = [];

  function paint() {
    var pure = hsv2rgb(hsv.h, 1, 1);
    field.style.background =
      'linear-gradient(to top, #000, transparent), ' +
      'linear-gradient(to right, #fff, ' + cssOf({ r: pure.r, g: pure.g, b: pure.b, a: 1 }) + ')';
    fdot.style.left = (hsv.s * 100) + '%';
    fdot.style.top = ((1 - hsv.v) * 100) + '%';
    hdot.style.left = (hsv.h * 100) + '%';
    sw.style.background = cssOf(c);
    hexbox.value = '#' + chex2(c.r) + chex2(c.g) + chex2(c.b) + (c.hasA ? chex2(c.a) : '');
    for (var i = 0; i < chans.length; i++) {
      var ch = chans[i];
      ch.sl.value = c[ch.k];
      ch.nb.value = cfmt(c[ch.k]);
    }
  }
  function fromHsv() {
    var n = hsv2rgb(hsv.h, hsv.s, hsv.v);
    c.r = n.r; c.g = n.g; c.b = n.b;
  }

  /* The two 2-D/1-D drags. Pointer events, captured, so a drag that leaves the
   * element still tracks and still ends -- a mouseup lost outside the popover
   * is how a picker gets stuck painting. */
  function dragger(elm, move) {
    function at(ev) {
      var b = elm.getBoundingClientRect();
      var x = (ev.clientX - b.left) / b.width, y = (ev.clientY - b.top) / b.height;
      move(Math.max(0, Math.min(1, x)), Math.max(0, Math.min(1, y)));
      paint();
      commit(false);
    }
    elm.onpointerdown = function (ev) {
      elm.setPointerCapture(ev.pointerId);
      elm.__drag = true; at(ev); ev.preventDefault();
    };
    elm.onpointermove = function (ev) { if (elm.__drag) at(ev); };
    elm.onpointerup = function (ev) {
      if (!elm.__drag) return;
      elm.__drag = false;
      try { elm.releasePointerCapture(ev.pointerId); } catch (e) {}
      commit(true);                         /* the drop always persists */
    };
    elm.onpointercancel = elm.onpointerup;
  }
  dragger(field, function (x, y) { hsv.s = x; hsv.v = 1 - y; fromHsv(); });
  dragger(hue, function (x) { hsv.h = x; fromHsv(); });

  /* R/G/B/A sliders + typed boxes. Alpha is offered only when the declared
   * value carried one -- see the note on `hasA`. */
  var keys = c.hasA ? ['r', 'g', 'b', 'a'] : ['r', 'g', 'b'];
  keys.forEach(function (k) {
    var line = el('div', 'cp-ch');
    var lab = el('span', 'cp-chl'); lab.textContent = k.toUpperCase();
    var sl = el('input', 'cp-chs');
    sl.type = 'range'; sl.min = 0; sl.max = 1; sl.step = 0.0001;
    var nb = el('input', 'cp-chn');
    nb.type = 'number'; nb.min = 0; nb.max = 1; nb.step = 0.01;
    sl.oninput = function () {
      c[k] = parseFloat(sl.value);
      if (k !== 'a') hsv = rgb2hsv(c);
      paint(); commit(false);
    };
    sl.onchange = function () { commit(true); };
    nb.onchange = function () {
      var v = parseFloat(nb.value);
      if (isNaN(v)) { paint(); return; }
      c[k] = Math.max(0, Math.min(1, v));
      if (k !== 'a') hsv = rgb2hsv(c);
      paint(); commit(true);
    };
    chans.push({ k: k, sl: sl, nb: nb });
    line.appendChild(lab); line.appendChild(sl); line.appendChild(nb);
    rows.appendChild(line);
  });

  hexbox.onchange = function () {
    var p = parseColor(hexbox.value.trim());
    /* A hex edit must not silently GAIN or LOSE the alpha channel the config
     * key is declared with; only the RGB (and A, when there already was one)
     * are taken. */
    c.r = p.r; c.g = p.g; c.b = p.b;
    if (c.hasA && p.hasA) c.a = p.a;
    hsv = rgb2hsv(c);
    paint(); commit(true);
  };

  sw.onclick = function () {
    pop.style.display = pop.style.display === 'none' ? 'block' : 'none';
  };
  pop.appendChild(field); pop.appendChild(hue); pop.appendChild(rows);
  var hexline = el('div', 'cp-hexline');
  var hexlab = el('span', 'cp-chl'); hexlab.textContent = 'HEX';
  hexline.appendChild(hexlab); hexline.appendChild(hexbox);
  pop.appendChild(hexline);
  wrap.appendChild(sw); wrap.appendChild(pop);
  paint();
  return wrap;
}

/* THE FALSIFIABLE NEGATIVE (CLAUDE.md 9b).
 *
 * The claim this project keeps needing to make is "every settings row is bound
 * to a real control". The tempting way to check it is to count the rows that
 * were wired -- which is a self-comparison and cannot fail: the counter is
 * incremented by the same code that does the wiring, so it agrees with itself
 * whatever happens.
 *
 * So the check is stated the other way round, as a property of the FINISHED
 * SCREEN that a change can break: after drawing, NO row fell through to the
 * generic text box carrying a type this switch does not deliberately handle.
 * The input that makes it fail is real and cheap to produce -- a mod declaring
 * a new `SettingType` whose `kindName` is not added here. It fails LOUDLY, on
 * screen, naming the offending keys, rather than rendering them as text boxes
 * that look bound and are not.
 *
 * Three outcomes, not two: an empty screen reports INCONCLUSIVE, because "no
 * rows were examined" is not "no rows are unbound". */
var BOUND_TYPES = ['bool', 'int', 'float', 'enum', 'select', 'string',
                   'keybind', 'color'];
var UNBOUND = [];

/* The one switch on `row.type`. Everything that draws a settings row in this
 * project goes through here. */
function controlFor(row, onSave) {
  var wrap = el('span', 'ctl');
  var e;
  if (row.type === 'bool') {
    e = el('input');
    e.type = 'checkbox';
    e.checked = !!row.value;
    e.onchange = function () { onSave(e.checked); };
  } else if (row.type === 'select' ||
             (row.type === 'enum' && ((row.options || []).length > INLINE_OPTION_MAX ||
                                      row.optionsUrl))) {
    e = typeahead(row, onSave);
  } else if (row.type === 'enum') {
    e = el('select');
    inlineOptions(row).forEach(function (o) {
      var opt = document.createElement('option');
      opt.value = o.value; opt.textContent = o.label;
      if (String(o.value) === String(row.value)) opt.selected = true;
      e.appendChild(opt);
    });
    e.onchange = function () { onSave(e.value); };
  } else if (row.type === 'int' || row.type === 'float') {
    e = numeric(row, onSave);
  } else if (row.type === 'color') {
    e = colorpicker(row, onSave);
  } else {
    /* string / keybind -- AND anything this switch has never heard of. That
     * fallthrough is the thing the check below exists to catch: a text box is a
     * reasonable degrade for a `string`, and a silent LIE for a type that was
     * supposed to get a real control. See BOUND_TYPES. */
    if (BOUND_TYPES.indexOf(row.type) < 0) UNBOUND.push(row.key + ' (' + row.type + ')');
    e = el('input');
    e.type = 'text';
    e.value = row.value;
    e.onchange = function () { onSave(e.value); };
  }
  wrap.appendChild(e);
  return wrap;
}

/* ---- the page -------------------------------------------------------- */

/* Rows put into the DOM per batch. Hundreds of rows across a dozen mods is
 * thousands of nodes if drawn eagerly; this draws a screenful and appends the
 * rest as the sentinel scrolls into view, so time-to-interactive does not
 * depend on how many settings exist. */
var CHUNK = 50;

function mount(root, opts) {
  opts = opts || {};
  var state = {
    mods: [], guid: null, rows: [], schemas: {},
    query: '', scope: 'mod', collapsed: {}, flat: [], drawn: 0, busy: false,
    /* Keybinds-only is PURE UI STATE. It is deliberately NOT a declared
     * setting: it changes nothing on the server, it would never reach
     * `onSettingsApplied`, and a key in some mod's config.json that no code
     * reads is exactly the inert row the `aowl build mods` gate exists to
     * refuse. It is remembered in localStorage and in the deep link instead. */
    kbOnly: false,
    /* The §9b counters, re-measured from the FINISHED list on every rebuild --
     * never incremented by the code that does the filtering. */
    kbAudit: null
  };

  root.innerHTML =
    '<nav id="aw-nav"><div class="aw-search"><input id="aw-q" type="search" placeholder="Search all settings"></div>' +
    '<label class="aw-scope"><input type="checkbox" id="aw-all"> search every mod</label>' +
    '<label class="aw-scope aw-kbscope"><input type="checkbox" id="aw-kb"> keybinds only</label>' +
    '<div id="aw-mods"></div><div id="aw-cats"></div></nav>' +
    '<main id="aw-main"><div id="aw-titlebar"><h1 id="aw-title">aowlspt settings</h1>' +
    '<span id="aw-count"></span><button id="aw-resetall" style="display:none">Reset everything to default</button></div>' +
    '<div id="aw-unbound" class="aw-verdict" style="display:none"></div>' +
    '<div id="aw-kbverdict" class="aw-verdict" style="display:none"></div>' +
    '<div id="aw-body"></div><div id="aw-sentinel"></div></main>';

  var $ = function (id) { return root.querySelector('#' + id); };
  var body = $('aw-body'), main = $('aw-main'), sentinel = $('aw-sentinel');

  /* ---- deep links: #guid=<guid>&cat=<category>&q=<query> ---- */
  function readHash() {
    var h = (location.hash || '').replace(/^#/, ''), out = {};
    h.split('&').forEach(function (p) {
      var i = p.indexOf('=');
      if (i > 0) out[p.substr(0, i)] = decodeURIComponent(p.substr(i + 1));
    });
    return out;
  }
  function writeHash(extra) {
    var parts = [];
    if (state.guid) parts.push('guid=' + encodeURIComponent(state.guid));
    if (extra && extra.cat) parts.push('cat=' + encodeURIComponent(extra.cat));
    /* `sub` is a SECOND key rather than a dotted `cat=Loot.Core`, because a
     * category name may itself contain a dot ("Player / Stamina" does not, but
     * nothing stops one) and a link that cannot be split back is not a link.
     * Before this, clicking a sub-tab wrote `cat=Core` -- a subcategory
     * recorded as though it were a top-level group, which then failed to
     * resolve on reload because no category is called Core. */
    if (extra && extra.sub) parts.push('sub=' + encodeURIComponent(extra.sub));
    if (state.query) parts.push('q=' + encodeURIComponent(state.query));
    if (state.kbOnly) parts.push('kb=1');
    var h = '#' + parts.join('&');
    if (location.hash !== h) history.replaceState(null, '', h);
  }

  function catId(guid, cat, sub) {
    return 'sec-' + btoa(unescape(encodeURIComponent(guid + '::' + cat + '::' + (sub || ''))))
                    .replace(/[^A-Za-z0-9]/g, '');
  }

  /* ---- flatten: sections + rows, honouring search and collapse ---- */
  function rebuild() {
    var flat = [], sources;
    if (state.scope === 'all') {
      sources = state.mods.map(function (m) { return {guid: m.guid, name: m.name, rows: state.schemas[m.guid] || []}; });
    } else {
      var m = state.mods.filter(function (x) { return x.guid === state.guid; })[0];
      sources = [{guid: state.guid, name: (m && m.name) || state.guid, rows: state.rows}];
    }
    var total = 0, shownCount = 0;
    sources.forEach(function (src) {
      var kept = src.rows.filter(function (r) {
        return matches(r, state.query) && (!state.kbOnly || isKeybindRow(r));
      });
      total += src.rows.length;
      shownCount += kept.length;
      if (!kept.length) return;
      if (state.scope === 'all') flat.push({t: 'mod', guid: src.guid, name: src.name, n: kept.length});
      groupRows(kept).forEach(function (g) {
        var key = src.guid + '::' + g.name;
        var isCollapsed = !!state.collapsed[key];
        var n = 0;
        g.subs.forEach(function (s) { n += s.rows.length; });
        if (g.name) flat.push({t: 'cat', guid: src.guid, name: g.name, n: n, key: key,
                               collapsed: isCollapsed, id: catId(src.guid, g.name)});
        if (isCollapsed) return;
        g.subs.forEach(function (s) {
          if (s.name) flat.push({t: 'sub', guid: src.guid, name: s.name,
                                 cat: g.name, id: catId(src.guid, g.name, s.name)});
          s.rows.forEach(function (r) { flat.push({t: 'row', guid: src.guid, row: r}); });
        });
      });
    });
    state.flat = flat;
    state.drawn = 0;
    UNBOUND = [];                 /* re-measured every render, never cumulative */
    body.innerHTML = '';
    $('aw-count').textContent = (state.query || state.kbOnly)
      ? shownCount + ' of ' + total + ' settings match'
      : total + ' settings';
    auditKeybinds(sources);
    drawMore();
    drawSidebar(sources);
    reportKeybinds();
  }

  /* ---- the §9b audit of the keybinds-only filter ----------------------
   *
   * Stated as two NEGATIVES over the FINISHED list, both of which a change can
   * falsify. Neither is a self-comparison: both walk `state.flat` (what the
   * screen will actually contain) and the untouched source schemas, not the
   * predicate's own bookkeeping.
   *
   *   1. shown  -- rows that ARE in the list but are NOT keybinds. Must be 0.
   *   2. hidden -- mods with >=1 declared keybind that the mod list dropped.
   *                Must be 0. This is the one a naive filter gets wrong.
   *
   * Third outcome, not a boolean: a mod whose schema has not been fetched has
   * an UNKNOWN keybind count. It is counted as `unknown`, never as zero, and it
   * is never hidden -- "I could not look" is not "there is nothing there". */
  function auditKeybinds(sources) {
    if (!state.kbOnly) { state.kbAudit = null; return; }
    var a = {shownNonKeybind: [], hiddenWithKeybind: [], unknownMods: [],
             shownRows: 0, noFacet: 0, modsWithKeybinds: 0};
    for (var i = 0; i < state.flat.length; i++) {
      var it = state.flat[i];
      if (it.t !== 'row') continue;
      a.shownRows++;
      if (!declaresKeybindFacet(it.row)) a.noFacet++;
      if (!isKeybindRow(it.row)) a.shownNonKeybind.push(it.guid + '/' + it.row.key);
    }
    var visible = {};
    sources.forEach(function (s) { visible[s.guid] = 1; });
    state.mods.forEach(function (m) {
      var sch = state.schemas[m.guid];
      if (!sch) { a.unknownMods.push(m.guid); return; }
      var n = sch.filter(isKeybindRow).length;
      if (n > 0) {
        a.modsWithKeybinds++;
        /* Hidden = has keybinds, yet the mod list would not offer it. In `mod`
         * scope only the open mod is a source, so the claim is about the
         * SIDEBAR, which is what the user navigates by. */
        if (!modListShows(m.guid)) a.hiddenWithKeybind.push(m.guid);
      }
    });
    state.kbAudit = a;
  }

  /* Whether the mod list offers this mod under the current filter. UNKNOWN
   * (schema not fetched) is `true` -- never hide what has not been examined. */
  function modListShows(guid) {
    if (!state.kbOnly) return true;
    var sch = state.schemas[guid];
    if (!sch) return true;
    return sch.some(isKeybindRow);
  }

  function reportKeybinds() {
    var b = $('aw-kbverdict');
    if (!b) return;
    var a = state.kbAudit;
    if (!a) { b.style.display = 'none'; b.textContent = ''; return; }
    b.style.display = 'block';
    var head = 'Keybinds only: ' + a.shownRows + ' rows shown, ' +
               a.modsWithKeybinds + ' mods have >=1 declared keybind. ';
    if (a.shownNonKeybind.length || a.hiddenWithKeybind.length) {
      b.className = 'aw-verdict aw-fail';
      b.textContent = 'FAIL: ' + head +
        a.shownNonKeybind.length + ' non-keybind rows are visible (' +
        a.shownNonKeybind.slice(0, 6).join(', ') + '); ' +
        a.hiddenWithKeybind.length + ' mods with keybinds were hidden (' +
        a.hiddenWithKeybind.slice(0, 6).join(', ') + ').';
      return;
    }
    if (a.shownRows === 0 || a.unknownMods.length || a.noFacet) {
      b.className = 'aw-verdict aw-inconc';
      b.textContent = 'INCONCLUSIVE: ' + head +
        (a.shownRows === 0
          ? 'No row was drawn, so nothing was examined -- an empty list is not proof the filter is right. '
          : '') +
        (a.unknownMods.length
          ? a.unknownMods.length + ' mods have no schema loaded, so their keybind count is UNKNOWN and they are still listed (' +
            a.unknownMods.slice(0, 6).join(', ') + '). '
          : '') +
        (a.noFacet
          ? a.noFacet + ' drawn rows carry no `keybind` field at all -- this backend predates the facet, so the filter cannot be trusted here. '
          : '');
      return;
    }
    b.className = 'aw-verdict aw-pass';
    b.textContent = 'PASS: ' + head +
      '0 non-keybind rows visible, 0 mods with keybinds hidden.';
  }

  function drawMore() {
    var end = Math.min(state.flat.length, state.drawn + CHUNK);
    for (var i = state.drawn; i < end; i++) body.appendChild(nodeFor(state.flat[i]));
    state.drawn = end;
    /* If the batch did not fill the viewport there is nothing to scroll and
     * the sentinel would never fire again -- keep going until it does. */
    if (state.drawn < state.flat.length && main.scrollHeight <= main.clientHeight + 40) drawMore();
    reportBinding();
  }

  /* The verdict for the check described above BOUND_TYPES. Deliberately scoped
   * to the rows ACTUALLY DRAWN so far -- the list is chunked, so claiming
   * anything about rows that have not been reached yet would be the "I could
   * not look, therefore PASS" failure this is written to avoid. */
  function reportBinding() {
    var banner = $('aw-unbound');
    if (!banner) return;
    var drawnRows = 0;
    for (var i = 0; i < state.drawn; i++) if (state.flat[i].t === 'row') drawnRows++;
    if (drawnRows === 0) {
      banner.style.display = 'block';
      banner.className = 'aw-verdict aw-inconc';
      banner.textContent = 'INCONCLUSIVE: no settings rows were drawn, so ' +
        'nothing was examined for unbound controls.';
      return;
    }
    if (UNBOUND.length === 0) {
      banner.style.display = 'none';
      banner.textContent = '';
      return;
    }
    banner.style.display = 'block';
    banner.className = 'aw-verdict aw-fail';
    banner.textContent = 'FAIL: ' + UNBOUND.length + ' of ' + drawnRows +
      ' drawn rows fell through to a plain text box because this UI has no ' +
      'control for their declared type -- ' + UNBOUND.slice(0, 8).join(', ') +
      (UNBOUND.length > 8 ? ', ...' : '') +
      '. They render but are not really bound.';
  }

  function nodeFor(item) {
    if (item.t === 'mod') {
      var mh = el('div', 'aw-modhead', item.name);
      mh.appendChild(el('small', null, ' ' + item.guid + ' -- ' + item.n));
      return mh;
    }
    if (item.t === 'cat') {
      var h = el('div', 'aw-cat' + (item.collapsed ? ' collapsed' : ''));
      h.id = item.id;
      h.appendChild(el('span', 'aw-caret', item.collapsed ? '+' : '-'));
      h.appendChild(el('span', 'aw-catname', item.name));
      h.appendChild(el('span', 'aw-catn', String(item.n)));
      h.onclick = function () {
        state.collapsed[item.key] = !state.collapsed[item.key];
        rebuild();
      };
      return h;
    }
    if (item.t === 'sub') {
      var s = el('div', 'aw-sub', item.name);
      s.id = item.id;
      return s;
    }
    return rowNode(item.guid, item.row);
  }

  function rowNode(guid, row) {
    var r = el('div', 'aw-row' + (row.implemented === false ? ' dim' : ''));
    var lab = el('div', 'aw-label');
    lab.appendChild(el('div', null, row.label || row.key));
    var meta = el('small', null, row.description || '');
    if (row.description) lab.appendChild(meta);
    lab.appendChild(el('small', 'aw-key', row.key));
    r.appendChild(lab);
    var saved = el('span', 'aw-saved', 'saved');
    var ctl = controlFor(row, async function (val) {
      var reply = await setValue(guid, row.key, val);
      if (replyOk(reply)) {
        saved.classList.add('show');
        setTimeout(function () { saved.classList.remove('show'); }, 900);
        refreshFrom(guid, reply);
      } else {
        alert('Did not save "' + row.key + '": ' + replyErr(reply));
        refreshFrom(guid, replyRows(reply));
      }
    });
    ctl.appendChild(saved);
    r.appendChild(ctl);
    var rb = el('button', 'aw-reset', 'Reset');
    rb.title = 'Reset this to its declared default';
    rb.onclick = async function () {
      var reply = await resetKey(guid, row.key);
      if (replyOk(reply)) refreshFrom(guid, reply);
      else alert('Reset of "' + row.key + '" did not persist: ' + replyErr(reply));
    };
    r.appendChild(rb);
    return r;
  }

  /* Re-render from the SERVER reply, so a value the backend clamped, coerced
   * or refused shows what actually landed rather than what was typed. The
   * whole list is rebuilt rather than the one row patched, because a mod is
   * free to change other rows in response to an edit. */
  function refreshFrom(guid, rows) {
    state.schemas[guid] = rows;
    if (guid === state.guid) state.rows = rows;
    var top = main.scrollTop;
    rebuild();
    main.scrollTop = top;
  }

  function drawSidebar(sources) {
    var mods = $('aw-mods');
    mods.innerHTML = '';
    var listed = 0;
    state.mods.forEach(function (m) {
      /* THE MOD-LIST HALF of the filter: a mod with zero declared keybinds
       * disappears entirely. A mod whose schema was never fetched is NOT
       * hidden (see `modListShows`) -- it is listed with its count marked
       * unknown, because hiding it would be a guess dressed up as an answer. */
      if (!modListShows(m.guid)) return;
      listed++;
      var sch = state.schemas[m.guid];
      var n = state.kbOnly
                ? (sch ? String(sch.filter(isKeybindRow).length) : '?')
                : String(m.count);
      var d = el('div', 'aw-mod' + (m.guid === state.guid && state.scope === 'mod' ? ' active' : ''),
                 m.name + ' (' + n + ')');
      d.onclick = function () { state.scope = 'mod'; $('aw-all').checked = false; open(m.guid); };
      mods.appendChild(d);
    });
    if (state.kbOnly && listed === 0) {
      mods.appendChild(el('div', 'aw-note',
        'No loaded mod declares a keybind. This is a real answer, not a blank ' +
        'screen: ' + state.mods.length + ' mods were examined.'));
    }
    var cats = $('aw-cats');
    cats.innerHTML = '';
    var seen = {};
    state.flat.forEach(function (item) {
      if (item.t !== 'cat' && item.t !== 'sub') return;
      if (seen[item.id]) return;
      seen[item.id] = 1;
      var d = el('div', item.t === 'cat' ? 'aw-navcat' : 'aw-navsub',
                 item.name + (item.t === 'cat' ? ' (' + item.n + ')' : ''));
      d.onclick = function () {
        var target = root.querySelector('#' + item.id);
        /* The section may not be drawn yet -- draw until it is, or say so
         * rather than doing nothing when the anchor is past the cursor. */
        var guard = 0;
        while (!target && state.drawn < state.flat.length && guard++ < 200) {
          drawMore();
          target = root.querySelector('#' + item.id);
        }
        /* Hash FIRST: the deep link is the durable half, and it must land
         * even where scrollIntoView does not exist (jsdom found this -- the
         * throw skipped the link entirely). */
        if (target) {
          writeHash(item.t === 'sub' ? {cat: item.cat, sub: item.name}
                                     : {cat: item.name});
          if (target.scrollIntoView) target.scrollIntoView({block: 'start'});
        }
      };
      cats.appendChild(d);
    });
  }

  async function open(guid, keepQuery) {
    state.guid = guid;
    $('aw-title').textContent = (state.mods.filter(function (m) { return m.guid === guid; })[0] || {name: guid}).name;
    $('aw-resetall').style.display = '';
    if (!state.schemas[guid]) state.schemas[guid] = await getSchema(guid);
    state.rows = state.schemas[guid];
    if (!keepQuery) writeHash();
    rebuild();
  }

  async function loadAll() {
    for (var i = 0; i < state.mods.length; i++) {
      var g = state.mods[i].guid;
      if (!state.schemas[g]) state.schemas[g] = await getSchema(g);
    }
  }

  $('aw-q').oninput = function () {
    state.query = $('aw-q').value;
    writeHash();
    rebuild();
  };
  /* Turning the filter ON loads EVERY schema first. Without that, a mod whose
   * keybind count is unknown could not be judged, and the tempting shortcut --
   * treat unknown as zero and hide it -- is precisely violation #2: a mod with
   * keybinds vanishing from the list. Loading first makes the answer knowable
   * rather than making the wrong guess cheap. */
  $('aw-kb').onchange = async function () {
    state.kbOnly = $('aw-kb').checked;
    try { global.localStorage.setItem('aowl.kbOnly', state.kbOnly ? '1' : '0'); } catch (e) {}
    if (state.kbOnly) {
      $('aw-count').textContent = 'loading every mod' + String.fromCharCode(0x2026);
      await loadAll();
      /* If the mod currently open has no keybinds, move to one that has --
       * landing on an empty page is indistinguishable from a broken filter. */
      if (state.scope === 'mod' && !modListShows(state.guid)) {
        var alt = state.mods.filter(function (m) { return modListShows(m.guid); })[0];
        if (alt) { await open(alt.guid, true); writeHash(); return; }
      }
    }
    writeHash();
    rebuild();
  };
  $('aw-all').onchange = async function () {
    state.scope = $('aw-all').checked ? 'all' : 'mod';
    if (state.scope === 'all') {
      $('aw-count').textContent = 'loading every mod' + String.fromCharCode(0x2026);
      await loadAll();
      $('aw-title').textContent = 'Every mod';
    } else if (state.guid) {
      $('aw-title').textContent = (state.mods.filter(function (m) { return m.guid === state.guid; })[0] || {name: state.guid}).name;
    }
    rebuild();
  };
  $('aw-resetall').onclick = async function () {
    var g = state.guid;
    if (!g) return;
    if (!confirm('Reset every setting on this page to its default? This discards everything you have set for ' + g + '.')) return;
    var reply = await resetAll(g);
    if (replyOk(reply)) refreshFrom(g, reply);
    else alert('Reset did not persist: ' + replyErr(reply));
  };

  if (global.IntersectionObserver) {
    new IntersectionObserver(function (es) {
      if (es[0].isIntersecting && state.drawn < state.flat.length) drawMore();
    }, {root: main, rootMargin: '400px'}).observe(sentinel);
  } else {
    main.onscroll = function () {
      if (main.scrollTop + main.clientHeight > main.scrollHeight - 400) drawMore();
    };
  }

  (async function () {
    try {
      state.mods = await listMods();
    } catch (e) {
      body.textContent = 'Could not reach the backend: ' + e;
      return;
    }
    if (!state.mods.length) {
      $('aw-mods').innerHTML = '<div class="aw-note">No mod has declared settings yet.</div>';
      body.textContent = 'Nothing to show: /aowlspt/settings/index returned no mods.';
      return;
    }
    var h = readHash();
    if (h.q) { state.query = h.q; $('aw-q').value = h.q; }
    /* The link wins over the remembered preference: a URL that says `kb=1` and
     * opens unfiltered is a link that does not work. */
    var stored = '0';
    try { stored = global.localStorage.getItem('aowl.kbOnly') || '0'; } catch (e) {}
    state.kbOnly = h.kb === '1' || (h.kb === undefined && stored === '1');
    $('aw-kb').checked = state.kbOnly;
    var want = h.guid && state.mods.some(function (m) { return m.guid === h.guid; }) ? h.guid : state.mods[0].guid;
    if (state.kbOnly) {
      await loadAll();
      if (!modListShows(want)) {
        var alt0 = state.mods.filter(function (m) { return modListShows(m.guid); })[0];
        if (alt0) want = alt0.guid;
      }
    }
    await open(want, true);
    if (h.cat) {
      var anchor = catId(want, h.cat, h.sub || '');
      var target = root.querySelector('#' + anchor);
      var guard = 0;
      while (!target && state.drawn < state.flat.length && guard++ < 200) {
        drawMore();
        target = root.querySelector('#' + anchor);
      }
      if (target && target.scrollIntoView) target.scrollIntoView({block: 'start'});
    }
  })();

  return state;
}

global.AowlSettings = {
  apiGet: apiGet, apiPost: apiPost,
  replyOk: replyOk, replyRows: replyRows, replyErr: replyErr,
  listMods: listMods, getSchema: getSchema,
  setValue: setValue, resetKey: resetKey, resetAll: resetAll,
  matches: matches, groupRows: groupRows,
  isKeybindRow: isKeybindRow, declaresKeybindFacet: declaresKeybindFacet,
  inlineOptions: inlineOptions, labelForValue: labelForValue,
  controlFor: controlFor, mount: mount
};
})(window);
"""

## The page: a shell. Every behaviour it has comes from `LibJs` over HTTP, so
## the shipped page and a third party's page run identical code.
const PageHtml = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>aowlspt settings</title>
<style>
  :root { color-scheme: dark; }
  body { font-family: -apple-system, Segoe UI, sans-serif; background:#141414; color:#ddd; margin:0; }
  #app { display:flex; height:100vh; }
  #aw-nav { width:260px; overflow-y:auto; background:#1c1c1c; border-right:1px solid #2c2c2c; padding:8px; box-sizing:border-box; }
  .aw-search input { width:100%; box-sizing:border-box; background:#222; color:#ddd; border:1px solid #333; border-radius:6px; padding:7px 9px; font-size:13px; }
  .aw-scope { display:block; font-size:11px; color:#888; margin:8px 2px 10px; cursor:pointer; }
  #aw-mods { border-bottom:1px solid #282828; padding-bottom:8px; margin-bottom:8px; }
  .aw-mod { padding:7px 10px; border-radius:6px; cursor:pointer; margin-bottom:2px; font-size:13px; }
  .aw-mod:hover { background:#2a2a2a; }
  .aw-mod.active { background:#3a5a8c; color:#fff; }
  .aw-navcat { padding:5px 10px; font-size:12px; color:#9fb6d8; cursor:pointer; border-radius:5px; }
  .aw-navsub { padding:3px 10px 3px 22px; font-size:11px; color:#7f8a99; cursor:pointer; border-radius:5px; }
  .aw-navcat:hover, .aw-navsub:hover { background:#262626; color:#fff; }
  .aw-note { color:#888; font-size:12px; padding:8px 10px; }
  #aw-main { flex:1; overflow-y:auto; padding:18px 26px 60vh; }
  #aw-titlebar { display:flex; align-items:center; gap:14px; margin:0 0 14px; position:sticky; top:0; background:#141414; padding:6px 0 10px; z-index:5; }
  #aw-title { font-size:16px; color:#ddd; font-weight:600; margin:0; }
  #aw-count { color:#777; font-size:12px; flex:1; }
  #aw-resetall { background:#4a2626; color:#e0a0a0; border:1px solid #5a3030; border-radius:4px; padding:6px 12px; font-size:12px; cursor:pointer; }
  #aw-resetall:hover { background:#5a2e2e; }
  .aw-modhead { font-size:14px; color:#fff; font-weight:600; margin:26px 0 4px; border-bottom:1px solid #333; padding-bottom:5px; }
  .aw-modhead small { color:#666; font-weight:400; font-size:11px; }
  .aw-cat { display:flex; align-items:center; gap:8px; font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:#7d99c9; margin:20px 0 6px; cursor:pointer; user-select:none; }
  .aw-cat:hover { color:#a9c4ee; }
  .aw-caret { font-size:10px; width:10px; }
  .aw-catn { color:#5c5c5c; font-size:11px; letter-spacing:0; }
  .aw-sub { font-size:11px; color:#8a8a8a; margin:12px 0 4px 2px; letter-spacing:.04em; }
  .aw-row { display:flex; align-items:center; justify-content:space-between; padding:7px 0; border-bottom:1px solid #232323; gap:16px; }
  .aw-label { flex:1; min-width:0; font-size:13px; }
  .aw-label small { display:block; color:#888; font-weight:400; margin-top:2px; font-size:11px; }
  .aw-label small.aw-key { color:#4d4d4d; font-family:ui-monospace, Consolas, monospace; }
  .aw-row.dim { opacity:.5; }
  .aw-row input[type=text], .aw-row select, .ta-input { background:#222; color:#ddd; border:1px solid #333; border-radius:4px; padding:5px 8px; min-width:170px; }
  .num { display:inline-flex; align-items:center; gap:10px; }
  .aw-verdict { margin:8px 0; padding:8px 10px; border-radius:5px; font-size:12px; line-height:1.5; }
  .aw-fail { background:#3a1f1f; border:1px solid #6a3030; color:#f0b0b0; }
  .aw-inconc { background:#332d1c; border:1px solid #63552c; color:#e6d29a; }
  .aw-pass { background:#1c2f22; border:1px solid #2f5a3d; color:#a8dfba; }
  .aw-kbscope { margin-top:-4px; }
  .aw-kbscope input:checked + span, label.aw-kbscope:has(input:checked) { color:#9fd8ae; }
  .cp { position:relative; display:inline-block; }
  .cp-sw { width:54px; height:26px; border:1px solid #444; border-radius:4px; cursor:pointer; padding:0;
           background-image:linear-gradient(45deg,#555 25%,transparent 25%,transparent 75%,#555 75%),
                            linear-gradient(45deg,#555 25%,transparent 25%,transparent 75%,#555 75%);
           background-size:8px 8px; background-position:0 0,4px 4px; }
  .cp-pop { position:absolute; right:0; top:30px; z-index:40; background:#1b1b1b; border:1px solid #383838;
            border-radius:7px; padding:10px; width:212px; box-shadow:0 6px 20px rgba(0,0,0,.6); }
  .cp-field { position:relative; height:120px; border-radius:4px; cursor:crosshair; touch-action:none; }
  .cp-dot { position:absolute; width:11px; height:11px; margin:-6px 0 0 -6px; border:2px solid #fff;
            border-radius:50%; box-shadow:0 0 2px #000; pointer-events:none; }
  .cp-hue { position:relative; height:13px; margin-top:9px; border-radius:3px; cursor:ew-resize; touch-action:none;
            background:linear-gradient(to right,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00); }
  .cp-hdot { position:absolute; top:-2px; width:5px; height:17px; margin-left:-3px; border:2px solid #fff;
             border-radius:3px; box-shadow:0 0 2px #000; pointer-events:none; }
  .cp-ch { display:flex; align-items:center; gap:6px; margin-top:6px; }
  .cp-chl { width:26px; font-size:10px; color:#8a8a8a; letter-spacing:.05em; }
  .cp-chs { flex:1; min-width:0; accent-color:#5a86c9; }
  .cp-chn { width:62px; background:#222; color:#ddd; border:1px solid #333; border-radius:4px;
            padding:2px 4px; font-size:11px; }
  .cp-hexline { display:flex; align-items:center; gap:6px; margin-top:8px; }
  .cp-hex { flex:1; min-width:0; background:#222; color:#ddd; border:1px solid #333; border-radius:4px;
            padding:3px 6px; font-size:11px; font-family:ui-monospace, Consolas, monospace; }
  .num-slider { width:150px; accent-color:#5a86c9; }
  .num-box { background:#222; color:#ddd; border:1px solid #333; border-radius:4px; padding:5px 8px; width:86px; }
  .aw-row input[type=checkbox] { width:18px; height:18px; }
  .ctl { display:inline-flex; align-items:center; }
  .ta { position:relative; display:inline-block; }
  .ta-list { position:absolute; z-index:20; right:0; top:100%; margin-top:2px; width:340px; max-height:280px; overflow-y:auto; background:#1d1d1d; border:1px solid #3a3a3a; border-radius:6px; box-shadow:0 8px 22px #000a; }
  .ta-opt { padding:6px 9px; font-size:12px; cursor:pointer; }
  .ta-opt small { display:block; color:#6a6a6a; font-family:ui-monospace, Consolas, monospace; font-size:10px; }
  .ta-opt.on, .ta-opt:hover { background:#33465f; }
  .ta-empty { padding:6px 9px; font-size:11px; color:#777; }
  .ta-note { font-size:10px; color:#a08a5a; }
  .aw-saved { color:#6fbf6f; font-size:11px; margin-left:8px; opacity:0; transition:opacity .2s; }
  .aw-saved.show { opacity:1; }
  .aw-reset { background:#262626; color:#aaa; border:1px solid #383838; border-radius:4px; padding:4px 9px; font-size:11px; cursor:pointer; }
  .aw-reset:hover { background:#333; color:#eee; }
</style>
</head>
<body>
<div id="app">Loading the settings client&hellip;</div>
<script src="/aowlspt/ui/lib/settings.js?ident=1"></script>
<script>
// The page owns nothing but this call. If the library route did not load, say
// so plainly rather than showing an empty frame that looks like "no settings".
if (window.AowlSettings) {
  AowlSettings.mount(document.getElementById('app'));
} else {
  document.getElementById('app').textContent =
    'Could not load /aowlspt/ui/lib/settings.js -- the settings client did not load, so nothing on this page will work.';
}
</script>
</body>
</html>
"""

proc onPage(url, body, session: string): string =
  result = PageHtml

proc onLib(url, body, session: string): string =
  result = LibJs

proc onSettings(url, body, session: string): string =
  ## `GET` serves the schema; a `POST` carrying `{"key":...,"value":...}`
  ## persists one row into this mod's `config.json`. Same contract every other
  ## mod's settings route has -- see `aowlspt/settings`.
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
  result = declaredSchemaReply(st).text

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server-side page; nothing to do on this side"
    return Ok
  # The native F12 overlay reads `launchHint` from this route at start-up and
  # obeys THE VALUE IT READS -- see `aowl_ov_hint_alpha` in
  # `abi/aowlspt_overlay.h`. It exists here, rather than as a bare host flag,
  # so that the "turn this off in Settings" the toast prints is true: the
  # toggle is a real row on a real settings page the player can reach.
  declareSettings(@[
    boolSetting("launchHint", "Show the \"Press F12\" hint at launch", true,
                category = "",
                description = "aowlspt original (settings UI). A small notice in the top-right corner, once per launch, that fades after a few seconds"),
    boolSetting("launchHintFallbackPage", "Advertise the browser settings page",
                false, category = "", implemented = false,
                description = "aowlspt original (settings UI). Not wired yet: the toast names the in-game screen only")],
    # NO NAV ENTRY OF ITS OWN. This mod is infrastructure -- one HTML fallback
    # page -- and a player asked, fairly, why "Browser Settings Page" was a
    # whole entry in the settings nav for one row. It is not, any more:
    # `mods/settingshub` renders these rows on its "Settings Panel" page and
    # forwards a write back here over `SettingsApplyQuery`.
    #
    # Everything else is UNCHANGED and must stay so. This mod is still the ONE
    # owner of `launchHint`: it keeps this guid, it keeps serving
    # `/aowlspt/settings/aowl.uihub` below, and it keeps the same key in the
    # same `config.json` -- so no stored value moves and there is nothing to
    # migrate. That is not a nicety: `abi/aowlspt_overlay.h` fetches this exact
    # URL at start-up and reads `launchHint` out of it BY NAME, so moving the
    # value to another mod would silently turn the launch hint back on.
    inIndex = false)
  if serve("/aowlspt/settings/" & ModGuid, onSettings) != Ok:
    warn "could not register the uihub settings route -- the launch hint's " &
         "off-switch will not appear in the settings surface"
  if serve(LibRoute, onLib) != Ok:
    warn "could not register " & LibRoute &
         " -- the settings page will load but do nothing"
  if serve(PageRoute, onPage) != Ok:
    warn "could not register " & PageRoute
  success ModName & " " & ModVersion & " serving " & PageRoute & " and " &
          LibRoute & " -- the same /aowlspt/settings/* routes the native F12 screen uses"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer},
  onLoad = onLoad)
