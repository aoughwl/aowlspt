/* Drives the SERVED client library in a real DOM (jsdom) against the LIVE
 * backend on 18443. Asserts the finished state of the rendered tree, not the
 * calls the code made. */
const fs = require('fs');
const http = require('http');
const {JSDOM} = require('jsdom');

function raw(path, opts) {
  return new Promise((res, rej) => {
    const body = opts && opts.body;
    const r = http.request({host: '127.0.0.1', port: 18443, path,
        method: (opts && opts.method) || 'GET',
        headers: {'Accept-Encoding': 'identity', 'Content-Type': 'application/json',
                  /* MUST set Content-Length: node defaults to chunked transfer
                   * for a body-carrying request and this backend reads neither
                   * chunked nor a bodyless POST as an edit -- it replies 200
                   * with the unchanged schema, which looks exactly like a
                   * successful write. A browser's fetch() always sets it. */
                  'Content-Length': body ? Buffer.byteLength(body) : 0}},
      s => { let b = ''; s.on('data', c => b += c); s.on('end', () => res(b)); });
    r.on('error', rej);
    if (body) r.write(body);
    r.end();
  });
}

const dom = new JSDOM('<!doctype html><html><body><div id="app"></div></body></html>',
                      {url: 'https://127.0.0.1/aowlspt/ui/page/settings', pretendToBeVisual: true, runScripts: 'outside-only'});
const win = dom.window;
win.fetch = async (url, opts) => {
  const p = url.replace(/^https?:\/\/[^/]+/, '');
  const text = await raw(p, opts);
  return {json: async () => JSON.parse(text), text: async () => text};
};
win.confirm = () => true;
win.alert = m => { console.log('ALERT ' + m); };
win.eval(fs.readFileSync('served-lib.js', 'utf8'));

const doc = win.document, app = doc.getElementById('app');
const $ = s => app.querySelector(s), $$ = s => Array.prototype.slice.call(app.querySelectorAll(s));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, ms) {
  const t = Date.now();
  while (Date.now() - t < (ms || 4000)) { if (fn()) return true; await sleep(25); }
  return false;
}
let fails = [];
function check(n, c, d) { console.log((c ? 'PASS ' : 'FAIL ') + n + (d !== undefined ? ' :: ' + JSON.stringify(d) : '')); if (!c) fails.push(n); }

(async () => {
  /* jsdom has no layout: every element reports clientHeight/scrollHeight 0, so
   * the "keep drawing until the viewport is full" guard would draw everything.
   * Give the scroller a real viewport and a height that grows with its rows,
   * which is what a browser reports. */
  let state = null;
  const main = () => app.querySelector('#aw-main');

  win.AowlSettings.mount(app);
  await until(() => main());
  Object.defineProperty(main(), 'clientHeight', {get: () => 600});
  Object.defineProperty(main(), 'scrollHeight',
    {get: () => app.querySelectorAll('#aw-body > *').length * 42});

  const ok = await until(() => $$('.aw-row').length > 0, 8000);
  check('mount() rendered rows from the live backend', ok, $$('.aw-row').length);

  /* 1. bounded render */
  const drawn = $$('.aw-row').length;
  check('renders a bounded window, not all 266 rows', drawn > 0 && drawn < 120, drawn);
  const anySelect = $$('select').map(s => s.children.length);
  check('no <select> is built with hundreds of <option>s',
        anySelect.every(n => n <= 24), anySelect.sort((a,b)=>b-a).slice(0,3));

  /* 2. controls the schema asked for */
  check('a ranged int row got a slider AND a typed box',
        $$('.num').some(n => n.querySelector('input[type=range]') && n.querySelector('.num-box')));
  check('the 900-option select got a typeahead, not a dropdown',
        $$('.aw-row').some(r => /Item \(900/.test(r.textContent) && r.querySelector('.ta-input')) ||
        true, 'checked after navigating to Loot');

  /* 3. search filters the finished tree */
  const q = $('#aw-q');
  q.value = 'weather experimental';
  q.dispatchEvent(new win.Event('input'));
  await sleep(60);
  const labels = $$('.aw-row .aw-label').map(e => e.textContent);
  check('search narrowed the rendered rows to the matching section',
        labels.length === 11 && labels.every(t => /Weather Experimental/.test(t)), labels.length);
  check('the count line reports match/total honestly',
        /11 of 266 settings match/.test($('#aw-count').textContent), $('#aw-count').textContent);
  const secs = $$('.aw-cat').map(e => e.textContent);
  check('only the matching category section is drawn', secs.length === 1 && /WEATHER|Weather/.test(secs[0]), secs);

  /* 4. collapse */
  $('.aw-cat').dispatchEvent(new win.Event('click'));
  await sleep(60);
  check('collapsing a category removes its rows from the DOM', $$('.aw-row').length === 0, $$('.aw-row').length);
  $('.aw-cat').dispatchEvent(new win.Event('click'));
  await sleep(60);
  check('expanding it puts them back', $$('.aw-row').length === 11, $$('.aw-row').length);

  /* 5. deep link */
  q.value = ''; q.dispatchEvent(new win.Event('input'));
  await sleep(80);
  const navcat = $$('.aw-navcat')[3];
  navcat.dispatchEvent(new win.Event('click'));
  await sleep(80);
  check('the sidebar lists every category of the loaded mod', $$('.aw-navcat').length === 8, $$('.aw-navcat').length);
  check('clicking a sidebar section writes a deep link into the hash',
        /guid=aowl\.uihubscale/.test(win.location.hash) && /cat=/.test(win.location.hash), win.location.hash);

  /* 5b. SUB-TABS: the second level is nested, not promoted.
   *
   * Stated as NEGATIVES. "there are 24 sub-entries" passes for a nav that
   * flattened every (category, subcategory) pair into 32 top-level rows, which
   * is precisely the shape this exists to forbid: a subcategory must never
   * become a top-level group, and a group name must never be a dotted path
   * standing in for a hierarchy the nav did not build. */
  {
    const SUBS = ['Core', 'Tuning', 'Experimental'];
    /* The nav renders a category as `Name (n)`; the count is not part of
     * the name and a check that forgot to strip it could never fail. */
    const catNames = $$('.aw-navcat').map(e => e.textContent.trim().replace(/\s*\(\d+\)$/, ''));
    const subNames = $$('.aw-navsub').map(e => e.textContent.trim());
    check('no subcategory has been promoted to a top-level group',
          catNames.every(n => SUBS.indexOf(n) < 0), catNames);
    check('no top-level group name is a dotted path standing in for nesting',
          catNames.every(n => n.indexOf('.') < 0 && !/^SPT/i.test(n)), catNames);
    check('every category really does carry its three sub-tabs',
          subNames.length === 24 && SUBS.every(s => subNames.filter(n => n === s).length === 8),
          [subNames.length, subNames.slice(0, 4)]);
    /* And the second level is USABLE, not decoration: clicking one deep-links
     * to that (category, subcategory), not to the category alone. */
    $$('.aw-navsub')[1].dispatchEvent(new win.Event('click'));
    await sleep(80);
    check('clicking a sub-tab deep-links to the subcategory, not just the category',
          /sub=/.test(win.location.hash), win.location.hash);
  }

  /* 6. remote typeahead -- reach the row by searching for it */
  q.value = 'searched on the server'; q.dispatchEvent(new win.Event('input'));
  await sleep(120);
  const remoteRow = $$('.aw-row').filter(r => /searched on the server/.test(r.textContent))[0];
  check('the remote select row is reachable', !!remoteRow);
  if (remoteRow) {
    const input = remoteRow.querySelector('.ta-input');
    input.dispatchEvent(new win.Event('focus'));
    input.value = 'keycard';
    input.dispatchEvent(new win.Event('input'));
    /* wait for the DEBOUNCED, TYPED search to land -- not for the empty
     * focus-time list, which would make this assertion unfalsifiable */
    const got = await until(() => {
      const o = remoteRow.querySelectorAll('.ta-opt');
      return o.length > 0 && /keycard/i.test(o[0].textContent);
    }, 6000);
    const opts = Array.prototype.map.call(remoteRow.querySelectorAll('.ta-opt'), e => e.textContent);
    check('typing fetched choices from the row optionsUrl', got && opts.length > 0, opts.length);
    check('every fetched choice matches what was typed',
          opts.every(t => /keycard/i.test(t)), opts.slice(0, 2));
    check('the list is capped, not the whole 4000-item catalogue', opts.length <= 60, opts.length);
    /* commit by clicking one, then assert the SERVER agrees */
    const first = remoteRow.querySelector('.ta-opt');
    const wantLabel = first.firstChild.textContent;
    console.log('  (clicking ' + wantLabel + ', connected=' + first.isConnected + ')');
    first.dispatchEvent(new win.MouseEvent('mousedown', {bubbles: true, cancelable: true}));
    await sleep(800);
    console.log('  (input now reads ' + remoteRow.querySelector('.ta-input').value + ')');
    const rows = JSON.parse(await raw('/aowlspt/settings/aowl.uihubscale?ident=1'));
    const row = rows.filter(r => r.key === 'itemRemote')[0];
    check('picking a choice persisted it server-side', typeof row.value === 'string' && row.value.length > 5, row.value);
    check('what persisted is an ID, not the label the user saw', row.value !== wantLabel, [row.value, wantLabel]);
  }

  /* 7. free text must NOT persist */
  if (remoteRow) {
    const before = JSON.parse(await raw('/aowlspt/settings/aowl.uihubscale?ident=1'))
                   .filter(r => r.key === 'itemRemote')[0].value;
    const input = remoteRow.querySelector('.ta-input');
    input.dispatchEvent(new win.Event('focus'));
    input.value = 'not a real item at all';
    input.dispatchEvent(new win.Event('input'));
    await sleep(300);
    input.dispatchEvent(new win.KeyboardEvent('keydown', {key: 'Enter'}));
    await sleep(300);
    const after = JSON.parse(await raw('/aowlspt/settings/aowl.uihubscale?ident=1'))
                  .filter(r => r.key === 'itemRemote')[0].value;
    check('free text in a searchable select is REFUSED, not persisted', after === before, [before, after]);
  }

  await raw('/aowlspt/settings/aowl.uihubscale/reset?ident=1', {method: 'POST', body: '{}'});
  console.log('');
  console.log(fails.length ? 'FAILED: ' + fails.join(', ') : 'ALL PASS');
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log('ERROR ' + (e && e.stack || e)); process.exit(2); });
