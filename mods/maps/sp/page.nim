## The draw surface: one page, three views, one feed.
##
## Served as a page plus a library, exactly the way `mods/uihub` serves the
## settings screen -- the page is a shell around `AowlSpatial.mount()` and has
## no private copy of anything, so a third-party page can load the same library
## and get the same views rather than reimplementing them and drifting.
##
## ---------------------------------------------------------------------------
## THE COORDINATE TRANSFORM, AND WHERE EVERY PART OF IT COMES FROM
## ---------------------------------------------------------------------------
##
## This is the part that cannot be guessed, so here is the derivation. Every
## step is read out of the fork's own source or its own calibration data; none
## of it is inferred from how a map looks.
##
## 1. **World -> map plane.** `Plugin/Utils/MathUtils.cs`,
##    `ConvertToMapPosition(Vector3 u) => new Vector3(u.x, u.z, u.y)`. Unity's
##    y is UP, so the horizontal plane is (x, z) and the 2D map point is
##    `(world.x, world.z)`. The third component, `world.y`, is the height and is
##    used ONLY to choose a layer.
##
## 2. **Map plane -> image.** Each layer's `imageBounds` (Min/Max, in map-plane
##    units) is the rectangle the layer art covers. `Plugin/README.md`: "+y is
##    upward on screen, so with CoordinateRotation 0 the top edge of the image
##    is ImageBounds.Max.y". SVG's y axis points DOWN, so the flip is
##    `svgY = Max.y - mapY` and `svgX = mapX - Min.x`.
##
## 3. **CoordinateRotation.** A whole-container rotation in degrees, from the
##    map's jsonc. Applied to the group holding the art AND the markers, about
##    the centre of the bounds, so art and markers rotate together and stay
##    registered. Marker GLYPHS are counter-rotated by the same angle so a dot's
##    label stays upright; that is cosmetic and affects no position.
##
## 4. **Layer choice by height.** A layer's `gameBounds` are world-space boxes
##    (with a real z range) that say "if the player is inside one of these, they
##    are on this layer". Where a layer has none, the layer is selected by hand.
##    Note the axis trap: in `gameBounds` the fork writes boxes in MAP-PLANE
##    coordinates with `z` as the HEIGHT (see Customs "zb-1011" at z -100..0.5),
##    i.e. the same `(x, y, z) = (world.x, world.z, world.y)` swap as step 1.
##    Getting this backwards would put the player underground on every map, so
##    it is applied once, in `inGameBounds`, and written down here.
##
## **What is NOT derived, and is therefore not drawn.** Player HEADING. The
## feed publishes `hasHeading:false` because no rotation field was measured
## (see `sp/world.nim`). So the radar draws NORTH-UP with a visible banner
## saying so, and the direction indicators are drawn as WORLD bearings, not
## as screen-relative arrows. A screen-relative arrow without a heading would
## be a confidently wrong picture -- it would point somewhere for every threat
## and be right only when the player happens to face north. Refusing to draw it
## is the honest option and the banner says which.
##
## ---------------------------------------------------------------------------
## THE THREE VIEWS
## ---------------------------------------------------------------------------
##
## * **Map** -- the terrain SVG for the chosen layer, with a marker per entity.
##   Pan, zoom, layer picker, follow-player toggle.
## * **Radar** -- the same entities clipped to `radiusM`, drawn on a range ring
##   centred on the player. No terrain, no calibration, so it works on a map
##   this repo has no art for.
## * **Indicators** -- the same entities reduced to a bearing and a distance,
##   drawn as arcs on a compass ring, nearest first. Bots and players are
##   distinguished; nothing else about them is claimed.
##
## Map selection is a stated HEURISTIC, not a fact: the page picks the map
## whose `bounds` contain the local player, preferring the smallest by area,
## and says in the UI that it inferred it and which one it picked. The raid's
## real location name is not in the feed, because reading it would be another
## game-memory hop this mod has not measured. A manual override is always
## available and always wins.

const LibJs* = """/* aowlspt spatial client -- window.AowlSpatial.
 * Served at /aowlspt/ui/lib/spatial.js by mods/maps. Map, radar and direction
 * indicators over one feed. No dependencies, no build step, no framework.
 *
 * Contract, in one line: everything here is arithmetic on /aowlspt/maps/feed,
 * and every number's derivation is in mods/maps/sp/page.nim. */
(function (global) {
'use strict';

/* ---- transport -------------------------------------------------------
 * `ident=1` asks the backend for an uncompressed response. The backend
 * deflates by default and never sends Content-Encoding, and the Fetch spec
 * forbids scripts from setting Accept-Encoding, so this query-string spelling
 * is the only way a browser can ask. Same reasoning as mods/uihub. */
function withIdent(p) { return p + (p.indexOf('?') >= 0 ? '&' : '?') + 'ident=1'; }
async function apiGet(p) {
  var r = await fetch(withIdent(p), {cache: 'no-store'});
  var t = await r.text();
  try { return JSON.parse(t); }
  catch (e) { return {err: 'the response from ' + p + ' was not JSON'}; }
}
async function apiText(p) {
  var r = await fetch(withIdent(p), {cache: 'no-store'});
  return r.text();
}

var A = '/aowlspt/maps/';

/* ---- the transform ---------------------------------------------------
 * Step 1 of the derivation in page.nim: the map plane is (world.x, world.z).
 * This is the ONLY place the swap happens; everything downstream is in map
 * coordinates and never sees a world vector again. */
function toMap(e) { return {x: e.x, y: e.z, h: e.y}; }

/* Step 4's axis trap, applied once. A gameBounds box is written in map-plane
 * coordinates with z as the HEIGHT. */
function inGameBounds(b, m) {
  return m.x >= Math.min(b.Min.x, b.Max.x) && m.x <= Math.max(b.Min.x, b.Max.x)
      && m.y >= Math.min(b.Min.y, b.Max.y) && m.y <= Math.max(b.Min.y, b.Max.y)
      && m.h >= Math.min(b.Min.z, b.Max.z) && m.h <= Math.max(b.Min.z, b.Max.z);
}

function boundsArea(b) {
  if (!b || !b.Min || !b.Max) return Infinity;
  return Math.abs(b.Max.x - b.Min.x) * Math.abs(b.Max.y - b.Min.y);
}
function inBounds(b, m) {
  if (!b || !b.Min || !b.Max) return false;
  return m.x >= Math.min(b.Min.x, b.Max.x) && m.x <= Math.max(b.Min.x, b.Max.x)
      && m.y >= Math.min(b.Min.y, b.Max.y) && m.y <= Math.max(b.Min.y, b.Max.y);
}

/* Map selection HEURISTIC, and it is a WEAK one. Returns {id, why, candidates}
 * or null.
 *
 * MEASURED by mods/maps/transform_test.js against the shipped calibration:
 * feeding each map's OWN centre back in resolves to that same map for only
 * 3 of 11 maps. The other 8 centres sit inside a smaller map's bounds as well,
 * because these rectangles overlap heavily around the origin -- Factory is
 * inside Customs, Labs is inside almost everything, and so on. So this
 * function is right about "which maps could this be" and mostly WRONG about
 * "which map is it".
 *
 * It is kept because a wrong first guess you can correct in one click beats no
 * guess at all, but it must never look authoritative. So `candidates` is
 * returned and the caller PRINTS it, and a hand-picked map always wins and is
 * never overridden. The real fix is the raid's location id, which is not in
 * the feed -- see README, "What would make map selection exact". */
function inferMap(index, local) {
  if (!local) return null;
  var m = toMap(local), best = null, n = 0;
  for (var i = 0; i < index.length; i++) {
    var e = index[i];
    if (!e.bounds || !inBounds(e.bounds, m)) continue;
    n++;
    if (!best || boundsArea(e.bounds) < boundsArea(best.bounds)) best = e;
  }
  if (!best) return null;
  return {id: best.id, candidates: n,
          why: n > 1
            ? ('GUESS: ' + n + ' maps contain this position; showing the ' +
               'smallest. Map bounds overlap, so this is often wrong -- pick ' +
               'the map by hand and it will stay picked.')
            : 'the only map whose bounds contain the player position'};
}

/* Layer choice. gameBounds first (a real, data-backed test); otherwise the
 * map's defaultLevel. Returns {name, why}. */
function pickLayer(map, local) {
  var names = Object.keys(map.layers || {});
  if (!names.length) return null;
  if (local) {
    var m = toMap(local);
    for (var i = 0; i < names.length; i++) {
      var L = map.layers[names[i]], gb = L.gameBounds || [];
      for (var j = 0; j < gb.length; j++) {
        if (inGameBounds(gb[j], m)) {
          return {name: names[i], why: 'the player is inside a gameBounds box ' +
                                       'declared for this layer'};
        }
      }
    }
  }
  for (var k = 0; k < names.length; k++) {
    if (map.layers[names[k]].level === (map.defaultLevel || 0)) {
      return {name: names[k], why: 'the map default level (no gameBounds box ' +
                                   'contains the player)'};
    }
  }
  return {name: names[0], why: 'first layer (no default level matched)'};
}

/* ---- geometry helpers ------------------------------------------------ */
function dist2(a, b) { var dx = a.x - b.x, dy = a.y - b.y; return dx*dx + dy*dy; }
/* Compass bearing in degrees, 0 = +y (map north), clockwise. */
function bearing(from, to) {
  var d = (Math.atan2(to.x - from.x, to.y - from.y) * 180 / Math.PI);
  return (d + 360) % 360;
}

/* ---- the feed -------------------------------------------------------- */
/* Four states, never flattened. `absent` and `not-armed` are INCONCLUSIVE and
 * must not be drawn as "no contacts". */
function feedVerdict(f) {
  if (!f) return {level: 'bad', text: 'no answer from ' + A + 'feed'};
  if (f.state === 'absent')
    return {level: 'bad', text: f.reason || 'no snapshot has ever been published'};
  if (f.state === 'no-host-export')
    return {level: 'bad', text: f.stateText};
  if (f.state === 'not-armed')
    return {level: 'bad', text: f.stateText};
  if (f.state === 'self-disabled')
    return {level: 'bad', text: 'the collector self-disabled after ' +
            f.faults + ' faults: ' + f.defect};
  if (f.state === 'armed-no-world')
    return {level: 'idle', text: 'no raid in progress (the collector is armed ' +
            'and the world cache is empty -- this IS a real answer)'};
  if (f.state === 'live' && !f.ok)
    return {level: 'idle', text: 'a world is live but no position validated: ' +
            (f.defect === 'none' ? 'no reason recorded' : f.defect)};
  return {level: 'ok', text: (f.ents || []).length + ' entities'};
}

/* ---- rendering ------------------------------------------------------- */
function svgEl(n, attrs) {
  var e = document.createElementNS('http://www.w3.org/2000/svg', n);
  for (var k in attrs) if (attrs[k] !== undefined && attrs[k] !== null)
    e.setAttribute(k, attrs[k]);
  return e;
}
function el(n, cls, txt) {
  var e = document.createElement(n);
  if (cls) e.className = cls;
  if (txt !== undefined) e.textContent = txt;
  return e;
}

/* CLASS colours, matched to the in-game widget's defaults so the browser map
 * and the overlay do not disagree about what a colour means. `cls` is 0 local,
 * 1 pmc, 2 scav, 3 boss, 4 unknown; anything else -- including an OLD snapshot
 * served by a host that predates the class feed, where `cls` is undefined --
 * falls to the unknown grey rather than to a confident wrong colour. */
var CLS_COL  = ['#ffffff', '#46beff', '#e6463c', '#ff3cdc', '#969696'];
var CLS_NAME = ['you', 'pmc', 'scav', 'boss', 'unclassified'];
function clsOf(e) {
  var c = (e && typeof e.cls === 'number') ? e.cls : 4;
  return (c >= 0 && c < 5) ? c : 4;
}
function colourOf(e) { return CLS_COL[clsOf(e)]; }
function labelOf(e)  { return CLS_NAME[clsOf(e)]; }

/* --- MAP view.
 * Steps 2 and 3 of the derivation. The <svg> viewBox spans the layer's
 * imageBounds in map units with y already flipped, so a marker at map (mx,my)
 * goes to (mx - Min.x, Max.y - my) with NO further scaling -- the browser does
 * the fit. CoordinateRotation is one rotate() on the group that holds both the
 * art and the markers, so they cannot come apart. */
function MapView(host) {
  var root = el('div', 'sp-map');
  host.appendChild(root);
  var svg = svgEl('svg', {width: '100%', height: '100%'});
  root.appendChild(svg);
  var gRot = svgEl('g', {});      svg.appendChild(gRot);
  var gArt = svgEl('g', {});      gRot.appendChild(gArt);
  var gMk  = svgEl('g', {});      gRot.appendChild(gMk);
  var state = {mapId: null, layer: null, bounds: null, rot: 0,
               view: null, follow: true};

  function applyViewBox() {
    var b = state.bounds; if (!b) return;
    var w = Math.abs(b.Max.x - b.Min.x), h = Math.abs(b.Max.y - b.Min.y);
    var v = state.view || {x: 0, y: 0, w: w, h: h};
    svg.setAttribute('viewBox', v.x + ' ' + v.y + ' ' + v.w + ' ' + v.h);
    gRot.setAttribute('transform',
      'rotate(' + state.rot + ' ' + (w / 2) + ' ' + (h / 2) + ')');
  }

  async function setLayer(map, layerName) {
    var L = map.layers[layerName];
    state.mapId = map.id; state.layer = layerName;
    state.bounds = L.imageBounds || map.bounds;
    state.rot = map.coordinateRotation || 0;
    state.view = null;
    while (gArt.firstChild) gArt.removeChild(gArt.firstChild);
    var txt = await apiText(A + 'asset/' + L.image);
    /* Inline the SVG rather than <image href>: an <img> would be a second
     * fetch the page cannot inspect, and a failed one renders as a broken
     * icon that looks like an empty map. Inlined, a refusal comment is
     * visible in the DOM and the banner can say so. */
    var doc = new DOMParser().parseFromString(txt, 'image/svg+xml');
    var src = doc.documentElement;
    var ok = src && src.nodeName.toLowerCase() === 'svg' && src.children.length;
    var b = state.bounds;
    var w = Math.abs(b.Max.x - b.Min.x), h = Math.abs(b.Max.y - b.Min.y);
    if (ok) {
      /* The art's own viewBox is its internal unit system; scale it onto the
       * layer's imageBounds rectangle. */
      var vb = (src.getAttribute('viewBox') || '').trim().split(/[ ,]+/).map(Number);
      var g = svgEl('g', {});
      if (vb.length === 4 && vb[2] > 0 && vb[3] > 0) {
        g.setAttribute('transform',
          'translate(' + (-vb[0] * w / vb[2]) + ',' + (-vb[1] * h / vb[3]) + ') ' +
          'scale(' + (w / vb[2]) + ',' + (h / vb[3]) + ')');
      }
      while (src.firstChild) g.appendChild(src.firstChild);
      gArt.appendChild(g);
    }
    applyViewBox();
    return ok;
  }

  function draw(feed) {
    while (gMk.firstChild) gMk.removeChild(gMk.firstChild);
    var b = state.bounds; if (!b) return;
    var ents = feed && feed.ents || [];
    for (var i = 0; i < ents.length; i++) {
      var m = toMap(ents[i]);
      var x = m.x - Math.min(b.Min.x, b.Max.x);
      var y = Math.max(b.Min.y, b.Max.y) - m.y;
      var w = Math.abs(b.Max.x - b.Min.x);
      var r = Math.max(w / 220, 2);
      var g = svgEl('g', {transform: 'translate(' + x + ',' + y + ') rotate(' +
                                     (-state.rot) + ')'});
      g.appendChild(svgEl('circle', {r: r, fill: colourOf(ents[i]),
                                     stroke: '#000', 'stroke-width': r * 0.3}));
      if (ents[i].me)
        g.appendChild(svgEl('circle', {r: r * 2.2, fill: 'none',
                                       stroke: '#4da3ff', 'stroke-width': r * 0.3,
                                       opacity: 0.7}));
      var t = svgEl('title', {}); t.textContent =
        labelOf(ents[i]) +
        (ents[i].id ? ' …' + ents[i].id : '') +
        '  world (' + ents[i].x.toFixed(1) + ', ' + ents[i].y.toFixed(1) +
        ', ' + ents[i].z.toFixed(1) + ')';
      g.appendChild(t);
      gMk.appendChild(g);
      if (ents[i].me && state.follow && state.view) {
        state.view.x = x - state.view.w / 2;
        state.view.y = y - state.view.h / 2;
        applyViewBox();
      }
    }
  }

  /* Pan and zoom. Plain pointer maths on the viewBox -- no library. */
  var drag = null;
  svg.addEventListener('pointerdown', function (ev) {
    var b = state.bounds; if (!b) return;
    if (!state.view) {
      state.view = {x: 0, y: 0, w: Math.abs(b.Max.x - b.Min.x),
                                h: Math.abs(b.Max.y - b.Min.y)};
    }
    drag = {x: ev.clientX, y: ev.clientY, vx: state.view.x, vy: state.view.y};
    state.follow = false;
    svg.setPointerCapture(ev.pointerId);
  });
  svg.addEventListener('pointermove', function (ev) {
    if (!drag) return;
    var r = svg.getBoundingClientRect();
    var sx = state.view.w / r.width, sy = state.view.h / r.height;
    state.view.x = drag.vx - (ev.clientX - drag.x) * sx;
    state.view.y = drag.vy - (ev.clientY - drag.y) * sy;
    applyViewBox();
  });
  svg.addEventListener('pointerup', function () { drag = null; });
  svg.addEventListener('wheel', function (ev) {
    var b = state.bounds; if (!b) return;
    ev.preventDefault();
    var W = Math.abs(b.Max.x - b.Min.x), H = Math.abs(b.Max.y - b.Min.y);
    if (!state.view) state.view = {x: 0, y: 0, w: W, h: H};
    var k = ev.deltaY > 0 ? 1.15 : 1 / 1.15;
    var nw = Math.min(W * 4, Math.max(W / 200, state.view.w * k));
    var nh = nw * (state.view.h / state.view.w);
    var r = svg.getBoundingClientRect();
    var fx = (ev.clientX - r.left) / r.width, fy = (ev.clientY - r.top) / r.height;
    state.view.x += (state.view.w - nw) * fx;
    state.view.y += (state.view.h - nh) * fy;
    state.view.w = nw; state.view.h = nh;
    state.follow = false;
    applyViewBox();
  }, {passive: false});

  return {root: root, setLayer: setLayer, draw: draw, state: state,
          resetView: function () { state.view = null; state.follow = true;
                                   applyViewBox(); }};
}

/* --- RADAR view. No terrain and no calibration, so it works on any map,
 * including one this repo ships no art for. North-up: see the note. */
function RadarView(host) {
  var root = el('div', 'sp-radar');
  host.appendChild(root);
  var svg = svgEl('svg', {viewBox: '-110 -110 220 220', width: '100%', height: '100%'});
  root.appendChild(svg);
  var gStatic = svgEl('g', {}); svg.appendChild(gStatic);
  var gBlip = svgEl('g', {});   svg.appendChild(gBlip);
  [100, 66, 33].forEach(function (r) {
    gStatic.appendChild(svgEl('circle', {r: r, fill: 'none', stroke: '#2c3a30',
                                         'stroke-width': 1}));
  });
  gStatic.appendChild(svgEl('line', {x1: 0, y1: -104, x2: 0, y2: 104,
                                     stroke: '#2c3a30', 'stroke-width': 1}));
  gStatic.appendChild(svgEl('line', {x1: -104, y1: 0, x2: 104, y2: 0,
                                     stroke: '#2c3a30', 'stroke-width': 1}));
  var nlab = svgEl('text', {x: 0, y: -106, fill: '#5c7a66', 'font-size': 9,
                            'text-anchor': 'middle'});
  nlab.textContent = 'N'; gStatic.appendChild(nlab);

  function draw(feed) {
    while (gBlip.firstChild) gBlip.removeChild(gBlip.firstChild);
    var ents = feed && feed.ents || [];
    var li = feed && feed.localIdx;
    if (li === undefined || li === null || li < 0 || !ents[li]) return 0;
    var me = toMap(ents[li]);
    var R = (feed.radiusM || 120);
    var shown = 0;
    for (var i = 0; i < ents.length; i++) {
      if (i === li) continue;
      var m = toMap(ents[i]);
      var dx = m.x - me.x, dy = m.y - me.y;
      var d = Math.sqrt(dx * dx + dy * dy);
      if (d > R) continue;
      /* Map +y is north; SVG y is down, so north is -y on the ring. */
      var px = dx / R * 100, py = -dy / R * 100;
      var g = svgEl('g', {transform: 'translate(' + px + ',' + py + ')'});
      g.appendChild(svgEl('circle', {r: 3.2, fill: colourOf(ents[i]),
                                     stroke: '#000', 'stroke-width': 0.8}));
      /* Height difference, the one thing a flat ring loses. Up/down chevron
       * only past 3 m, so ordinary terrain does not produce noise. */
      var dh = ents[i].y - ents[li].y;
      if (Math.abs(dh) > 3) {
        var c = svgEl('text', {x: 5, y: 2, fill: colourOf(ents[i]),
                               'font-size': 7});
        c.textContent = dh > 0 ? '▲' : '▼';
        g.appendChild(c);
      }
      var t = svgEl('title', {});
      t.textContent = labelOf(ents[i]) + ' ' + d.toFixed(0) +
                      ' m' + (Math.abs(dh) > 3 ? ', ' + dh.toFixed(0) + ' m vertical' : '');
      g.appendChild(t);
      gBlip.appendChild(g);
      shown++;
    }
    return shown;
  }
  return {root: root, draw: draw};
}

/* --- INDICATORS view. The same entities reduced to bearing + distance. Arcs
 * on a compass ring, nearest first. WORLD bearings, not screen-relative: see
 * the heading note in page.nim for why a screen-relative arrow is refused. */
function IndicatorView(host) {
  var root = el('div', 'sp-ind');
  host.appendChild(root);
  var svg = svgEl('svg', {viewBox: '-60 -60 120 120', width: '160', height: '160'});
  root.appendChild(svg);
  var gArc = svgEl('g', {}); svg.appendChild(gArc);
  svg.appendChild(svgEl('circle', {r: 40, fill: 'none', stroke: '#2b2b2b',
                                   'stroke-width': 1}));
  ['N', 'E', 'S', 'W'].forEach(function (n, i) {
    var a = i * 90 * Math.PI / 180;
    var t = svgEl('text', {x: Math.sin(a) * 50, y: -Math.cos(a) * 50 + 3,
                           fill: '#666', 'font-size': 8, 'text-anchor': 'middle'});
    t.textContent = n; svg.appendChild(t);
  });
  var list = el('div', 'sp-ind-list'); root.appendChild(list);

  function arcPath(deg, spread, r0, r1) {
    var a0 = (deg - spread) * Math.PI / 180, a1 = (deg + spread) * Math.PI / 180;
    function P(a, r) { return [Math.sin(a) * r, -Math.cos(a) * r]; }
    var p0 = P(a0, r0), p1 = P(a1, r0), p2 = P(a1, r1), p3 = P(a0, r1);
    return 'M' + p0 + 'A' + r0 + ',' + r0 + ' 0 0 1 ' + p1 +
           'L' + p2 + 'A' + r1 + ',' + r1 + ' 0 0 0 ' + p3 + 'Z';
  }

  function draw(feed) {
    while (gArc.firstChild) gArc.removeChild(gArc.firstChild);
    list.innerHTML = '';
    var ents = feed && feed.ents || [];
    var li = feed && feed.localIdx;
    if (li === undefined || li === null || li < 0 || !ents[li]) return 0;
    var me = toMap(ents[li]);
    var R = (feed.radiusM || 120);
    var rows = [];
    for (var i = 0; i < ents.length; i++) {
      if (i === li) continue;
      var m = toMap(ents[i]);
      var d = Math.sqrt(dist2(me, m));
      if (d > R) continue;
      rows.push({b: bearing(me, m), d: d, e: ents[i],
                 dh: ents[i].y - ents[li].y});
    }
    rows.sort(function (a, b) { return a.d - b.d; });
    for (var j = 0; j < rows.length; j++) {
      /* Closer contacts read as brighter and thicker -- the whole point of an
       * indicator is a glance, and distance is the only ranking that matters. */
      var t = 1 - Math.min(1, rows[j].d / R);
      gArc.appendChild(svgEl('path', {
        d: arcPath(rows[j].b, 7, 42, 42 + 4 + t * 10),
        fill: colourOf(rows[j].e), opacity: 0.25 + t * 0.65}));
      if (j < 8) {
        var row = el('div', 'sp-ind-row');
        row.appendChild(el('span', 'sp-dot'));
        row.lastChild.style.background = colourOf(rows[j].e);
        row.appendChild(el('span', 'sp-ind-b', Math.round(rows[j].b) + '°'));
        row.appendChild(el('span', 'sp-ind-d', Math.round(rows[j].d) + ' m'));
        row.appendChild(el('span', 'sp-ind-k',
          labelOf(rows[j].e) +
          (Math.abs(rows[j].dh) > 3
            ? (rows[j].dh > 0 ? ' ▲' : ' ▼') + Math.abs(Math.round(rows[j].dh))
            : '')));
        list.appendChild(row);
      }
    }
    return rows.length;
  }
  return {root: root, draw: draw};
}

/* ---- mount ----------------------------------------------------------- */
async function mount(host, opts) {
  opts = opts || {};
  host.innerHTML = '';
  var bar = el('div', 'sp-bar'); host.appendChild(bar);
  var banner = el('div', 'sp-banner'); host.appendChild(banner);
  var body = el('div', 'sp-body'); host.appendChild(body);
  var left = el('div', 'sp-left'); body.appendChild(left);
  var right = el('div', 'sp-right'); body.appendChild(right);

  var mapSel = el('select', 'sp-sel');
  var laySel = el('select', 'sp-sel');
  var followBtn = el('button', 'sp-btn', 'centre on me');
  var mapWhy = el('span', 'sp-why');
  bar.appendChild(el('span', 'sp-lbl', 'map'));   bar.appendChild(mapSel);
  bar.appendChild(el('span', 'sp-lbl', 'layer')); bar.appendChild(laySel);
  bar.appendChild(followBtn);
  bar.appendChild(mapWhy);

  var mapV = MapView(left);
  right.appendChild(el('div', 'sp-h', 'radar'));
  var radarV = RadarView(right);
  var radarNote = el('div', 'sp-note'); right.appendChild(radarNote);
  right.appendChild(el('div', 'sp-h', 'indicators'));
  var indV = IndicatorView(right);

  var index = [], maps = {}, current = null, curLayer = null, userPickedMap = false;

  var ix = await apiGet(A + 'index');
  if (ix && ix.err) {
    banner.className = 'sp-banner bad';
    banner.textContent = ix.err;
  }
  index = (ix && ix.maps) || [];

  async function loadMap(id) {
    if (maps[id]) return maps[id];
    var m = await apiGet(A + 'map/' + id);
    if (m && m.err) return null;
    maps[id] = m;
    return m;
  }
  /* The index carries no bounds (it is a summary), so fetch each map's full
   * record once for the inference test. 11 small documents, once per page. */
  async function hydrate() {
    for (var i = 0; i < index.length; i++) {
      var m = await loadMap(index[i].id);
      if (m) index[i].bounds = m.bounds;
    }
  }
  await hydrate();

  index.forEach(function (m) {
    var o = el('option', null, m.displayName); o.value = m.id; mapSel.appendChild(o);
  });

  async function selectMap(id, why) {
    var m = await loadMap(id); if (!m) return;
    current = m; mapSel.value = id; mapWhy.textContent = why || '';
    laySel.innerHTML = '';
    Object.keys(m.layers).forEach(function (n) {
      var o = el('option', null, n + '  (level ' + m.layers[n].level + ')');
      o.value = n; laySel.appendChild(o);
    });
    curLayer = null;
  }
  async function selectLayer(name, why) {
    if (!current || curLayer === name) return;
    curLayer = name; laySel.value = name;
    var ok = await mapV.setLayer(current, name);
    if (!ok) {
      banner.className = 'sp-banner bad';
      banner.textContent = 'the terrain asset for layer "' + name +
        '" did not parse as SVG -- the map is blank for a REASON, not because ' +
        'the raid is empty. Check ' + A + 'asset/' + current.layers[name].image;
    }
  }
  mapSel.onchange = async function () {
    userPickedMap = true;
    await selectMap(mapSel.value, 'chosen by hand');
    var p = pickLayer(current, null); if (p) await selectLayer(p.name, p.why);
  };
  laySel.onchange = function () { selectLayer(laySel.value, 'chosen by hand'); };
  followBtn.onclick = function () { mapV.resetView(); };

  if (index.length) await selectMap(index[0].id, 'first map (no feed yet)');
  if (current) { var p0 = pickLayer(current, null); if (p0) await selectLayer(p0.name, p0.why); }

  var lastSeq = -1, stalled = 0;
  async function tick() {
    var f = await apiGet(A + 'feed');
    var v = feedVerdict(f);
    /* A snapshot whose seq has not moved means the client stopped publishing.
     * That is INCONCLUSIVE and is reported as such -- it is not "no contacts",
     * and the check is on the FINISHED state (the seq the file carries), not
     * on whether our own fetch succeeded. */
    if (f && f.seq === lastSeq) { stalled++; } else { stalled = 0; lastSeq = f && f.seq; }
    var stale = stalled > 6;

    var local = null;
    if (f && f.ents && f.localIdx >= 0) local = f.ents[f.localIdx];

    if (local && !userPickedMap) {
      var g = inferMap(index, local);
      if (g && (!current || current.id !== g.id)) {
        await selectMap(g.id, g.why);
        var pl = pickLayer(current, local); if (pl) await selectLayer(pl.name, pl.why);
      } else if (current) {
        var pl2 = pickLayer(current, local);
        if (pl2 && pl2.name !== curLayer) await selectLayer(pl2.name, pl2.why);
      }
    }

    mapV.draw(f);
    var nRadar = radarV.draw(f);
    var nInd = indV.draw(f);

    radarNote.textContent = (f && f.hasHeading)
      ? 'oriented to the player'
      : 'NORTH-UP: player heading is not measured on this build, so nothing ' +
        'here is rotated to face the player. Bearings are world bearings.';

    if (stale) {
      banner.className = 'sp-banner bad';
      banner.textContent = 'the snapshot has not changed for ' + stalled +
        ' polls -- the client stopped publishing. INCONCLUSIVE: this is not ' +
        '"no contacts". Last state was: ' + v.text;
    } else {
      banner.className = 'sp-banner ' + v.level;
      banner.textContent = v.text +
        (v.level === 'ok' ? '  ·  radar ' + nRadar + ', indicators ' + nInd : '');
    }
    setTimeout(tick, opts.pollMs || 250);
  }
  tick();
}

global.AowlSpatial = {
  mount: mount, toMap: toMap, bearing: bearing, inferMap: inferMap,
  pickLayer: pickLayer, feedVerdict: feedVerdict,
  MapView: MapView, RadarView: RadarView, IndicatorView: IndicatorView
};
})(window);
"""

const PageHtml* = """<!doctype html>
<html><head><meta charset="utf-8"><title>Spatial</title>
<style>
  html,body { height:100%; margin:0; background:#131313; color:#ddd;
              font-family: -apple-system, Segoe UI, Roboto, sans-serif; }
  #app { display:flex; flex-direction:column; height:100%; }
  .sp-bar { display:flex; align-items:center; gap:8px; padding:8px 12px;
            background:#1b1b1b; border-bottom:1px solid #2a2a2a; flex:none; }
  .sp-lbl { font-size:11px; color:#888; text-transform:uppercase; letter-spacing:.06em; }
  .sp-sel { background:#242424; color:#ddd; border:1px solid #383838;
            border-radius:4px; padding:4px 6px; font-size:12px; }
  .sp-btn { background:#262626; color:#bbb; border:1px solid #383838;
            border-radius:4px; padding:4px 10px; font-size:12px; cursor:pointer; }
  .sp-btn:hover { background:#333; color:#eee; }
  .sp-why { font-size:11px; color:#7a7a7a; margin-left:auto; text-align:right; }
  .sp-banner { padding:6px 12px; font-size:12px; flex:none; }
  .sp-banner.ok   { background:#16241a; color:#7fbf87; }
  .sp-banner.idle { background:#241f16; color:#bfa76f; }
  .sp-banner.bad  { background:#2a1818; color:#e08b8b; }
  .sp-body { display:flex; flex:1; min-height:0; }
  .sp-left { flex:1; min-width:0; position:relative; }
  .sp-right { width:220px; flex:none; border-left:1px solid #2a2a2a;
              padding:10px; overflow-y:auto; background:#171717; }
  .sp-map { position:absolute; inset:0; background:#0d0d0d; cursor:grab; }
  .sp-map:active { cursor:grabbing; }
  .sp-h { font-size:10px; color:#777; text-transform:uppercase;
          letter-spacing:.08em; margin:4px 0 6px; }
  .sp-radar { background:#0e130f; border-radius:6px; }
  .sp-note { font-size:10px; color:#7a6f52; margin:6px 0 12px; line-height:1.4; }
  .sp-ind { display:flex; flex-direction:column; align-items:center; }
  .sp-ind-list { width:100%; margin-top:6px; }
  .sp-ind-row { display:flex; align-items:center; gap:6px; font-size:11px;
                padding:2px 0; color:#bbb; }
  .sp-dot { width:8px; height:8px; border-radius:50%; flex:none; }
  .sp-ind-b { width:38px; color:#999; font-family:ui-monospace,Consolas,monospace; }
  .sp-ind-d { width:44px; font-family:ui-monospace,Consolas,monospace; }
  .sp-ind-k { color:#777; }
</style></head>
<body>
<div id="app">Loading the spatial client&hellip;</div>
<script src="/aowlspt/ui/lib/spatial.js?ident=1"></script>
<script>
// The page owns nothing but this call. If the library route did not load, say
// so plainly rather than showing an empty frame that reads as "no contacts".
if (window.AowlSpatial) {
  AowlSpatial.mount(document.getElementById('app'));
} else {
  document.getElementById('app').textContent =
    'Could not load /aowlspt/ui/lib/spatial.js -- nothing on this page will work.';
}
</script>
</body></html>
"""

const
  PageRoute* = "/aowlspt/ui/page/spatial"
  LibRoute*  = "/aowlspt/ui/lib/spatial.js"
