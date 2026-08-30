/* Does the uihub settings page draw a read-only row as something the player
 * cannot type into?
 *
 * This asserts a property of the FINISHED DOM -- the node `controlFor` actually
 * returns -- not a property of the code that builds it. The check is a
 * NEGATIVE, and it is two-sided so that it can fail in both directions:
 *
 *   A. no row the schema marks readOnly renders any editable element
 *      (input / select / textarea / contenteditable)
 *   B. every row the schema does NOT mark readOnly renders at least one
 *
 * B is what stops A from being a check that cannot fail: without it, a
 * renderer that drew nothing at all for every row would pass A perfectly.
 *
 * It runs the SHIPPED library source, sliced straight out of mods/uihub/uihub.nim,
 * so it cannot drift from what the browser is served.
 *
 *   node tests/uihubreadonly/check.js [path-to-uihub.nim]
 *
 * Exit 0 = PASS, 1 = FAIL, 2 = INCONCLUSIVE (could not even run the check).
 */
'use strict';
const fs = require('fs');
const path = require('path');

function inconclusive(msg) { console.log('INCONCLUSIVE: ' + msg); process.exit(2); }

const nimPath = process.argv[2] ||
  path.join(__dirname, '..', '..', 'mods', 'uihub', 'uihub.nim');
let src;
try { src = fs.readFileSync(nimPath, 'utf8'); }
catch (e) { inconclusive('cannot read ' + nimPath + ': ' + e.message); }

/* ---- slice out the LibJs string literal ---- */
const marker = 'const LibJs = """';
const start = src.indexOf(marker);
if (start < 0) inconclusive('no `' + marker + '` in ' + nimPath);
const bodyStart = start + marker.length;
const end = src.indexOf('\n"""', bodyStart);
if (end < 0) inconclusive('LibJs literal is not terminated');
const js = src.slice(bodyStart, end);
if (js.indexOf('function controlFor') < 0)
  inconclusive('the slice does not contain controlFor -- the literal moved');

/* ---- the smallest DOM the library needs ---- */
function Node(tag) {
  this.tagName = String(tag).toUpperCase();
  this.children = []; this.attrs = {}; this.style = {};
  this.className = ''; this.textContent = ''; this.value = '';
  this.classList = {
    _n: this,
    add: function (c) { this._n.className = (this._n.className + ' ' + c).trim(); },
    remove: function () {},
    contains: function (c) { return (' ' + this._n.className + ' ').indexOf(' ' + c + ' ') >= 0; }
  };
}
Node.prototype.appendChild = function (c) { this.children.push(c); return c; };
Node.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
Node.prototype.querySelector = function () { return null; };
Node.prototype.addEventListener = function () {};

const document = {
  createElement: function (t) { return new Node(t); },
  createTextNode: function (t) { const n = new Node('#text'); n.textContent = t; return n; },
  querySelector: function () { return null; },
  addEventListener: function () {}
};

const sandbox = {
  window: {}, document: document, console: console,
  location: { hash: '' }, history: { replaceState: function () {} },
  setTimeout: setTimeout, clearTimeout: clearTimeout,
  fetch: function () { return Promise.reject(new Error('no network in this check')); },
  btoa: function (s) { return Buffer.from(s, 'binary').toString('base64'); },
  unescape: function (s) { return s; },
  encodeURIComponent: encodeURIComponent, decodeURIComponent: decodeURIComponent,
  alert: function () {}, IntersectionObserver: function () {
    this.observe = function () {}; this.disconnect = function () {};
  }
};
sandbox.window.document = document;
sandbox.globalThis = sandbox;

const vm = require('vm');
vm.createContext(sandbox);
try { vm.runInContext(js, sandbox, {filename: 'uihub:LibJs'}); }
catch (e) { inconclusive('the library source did not evaluate: ' + e.message); }

const A = sandbox.window.AowlSettings;
if (!A || typeof A.controlFor !== 'function')
  inconclusive('window.AowlSettings.controlFor was not exported');

/* ---- walk the produced node for anything editable ---- */
const EDITABLE = {INPUT: 1, SELECT: 1, TEXTAREA: 1, BUTTON: 1};
function editableIn(node, out) {
  out = out || [];
  if (!node) return out;
  if (EDITABLE[node.tagName]) out.push(node.tagName.toLowerCase());
  if (node.attrs && node.attrs.contenteditable) out.push('contenteditable');
  (node.children || []).forEach(function (c) { editableIn(c, out); });
  return out;
}

/* ---- the rows under test ----
 * Deliberately includes one row of every kind the schema can emit, so B has
 * real breadth, plus the row this change exists for. `readOnly` is what the
 * backend now always emits (settings.toJson, from isReadOnly). */
const rows = [
  {key: 'lootSummary', label: 'What this configuration does', type: 'text',
   value: 'containers 1.0x, loose 1.0x', readOnly: true},
  {key: 'spawnResultLike', label: 'read-only, no explicit flag', type: 'text',
   value: 'x'},                                   /* fallback path: type alone */
  {key: 'lootEnabled', type: 'bool', value: true, readOnly: false},
  {key: 'lootGlobalMultiplier', type: 'float', value: 1.0,
   min: 0.0, max: 10.0, step: 0.1, readOnly: false},
  {key: 'maxLootItems', type: 'int', value: 20000,
   min: 0, max: 200000, step: 1000, readOnly: false},
  {key: 'lootPreset', type: 'enum', value: 'custom',
   options: ['custom', 'vanilla', 'scarce', 'richer', 'goblin'], readOnly: false},
  {key: 'spawnQuery', type: 'string', value: '', readOnly: false},
  {key: 'zoomToggleKey', type: 'keybind', value: 'M', readOnly: false},
  {key: 'spawnItem', type: 'select', value: '', options: [],
   optionsUrl: '/aowlspt/tarkov/items', readOnly: false}
];

let fails = [];
let sawReadOnly = 0, sawEditable = 0;
rows.forEach(function (row) {
  let node;
  try { node = A.controlFor(row, function () {}); }
  catch (e) { fails.push(row.key + ': controlFor threw: ' + e.message); return; }
  const found = editableIn(node);
  const ro = A.isReadOnlyRow ? A.isReadOnlyRow(row)
                             : (row.readOnly !== undefined ? !!row.readOnly : row.type === 'text');
  if (ro) {
    sawReadOnly++;
    if (found.length)
      fails.push('A: read-only row "' + row.key + '" (type ' + row.type +
                 ') rendered editable element(s): ' + found.join(', '));
  } else {
    sawEditable++;
    if (!found.length)
      fails.push('B: editable row "' + row.key + '" (type ' + row.type +
                 ') rendered NO editable element -- it cannot be changed');
  }
});

/* Secondary, and the reason no NEW slider/enum kind was built: the loot page's
 * ranged numeric rows must already get a range input, and its 5-option enum a
 * <select>. Asserted on the produced DOM for the same reason as above. */
function tagsIn(node, out) {
  out = out || [];
  if (!node) return out;
  out.push(node.tagName + (node.type ? ':' + node.type : ''));
  (node.children || []).forEach(function (c) { tagsIn(c, out); });
  return out;
}
[['lootGlobalMultiplier', 'INPUT:range'], ['maxLootItems', 'INPUT:range'],
 ['lootPreset', 'SELECT']].forEach(function (want) {
  const row = rows.filter(function (r) { return r.key === want[0]; })[0];
  if (!row) { fails.push('fixture lost row ' + want[0]); return; }
  const tags = tagsIn(A.controlFor(row, function () {}));
  if (tags.indexOf(want[1]) < 0)
    fails.push('C: "' + row.key + '" (type ' + row.type + ') drew ' +
               tags.join(',') + ' -- no ' + want[1]);
});

if (!sawReadOnly || !sawEditable)
  inconclusive('the fixture no longer covers both sides (readOnly=' +
               sawReadOnly + ', editable=' + sawEditable + ')');

if (fails.length) {
  console.log('FAIL (' + fails.length + ')');
  fails.forEach(function (f) { console.log('  ' + f); });
  process.exit(1);
}
console.log('PASS: ' + sawReadOnly + ' read-only row(s) rendered no editable element; ' +
            sawEditable + ' editable row(s) each rendered one.');
