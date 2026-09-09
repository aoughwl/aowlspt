/* Runs the SERVED bytes of the client library (served-lib.js, fetched over
 * HTTP by verify.py) and exercises the pure parts against the SERVED schema.
 * No jsdom here, so mount()/controlFor() are not covered -- see the report. */
const fs = require('fs');
const vm = require('vm');
const http = require('http');

function get(path) {
  return new Promise((res, rej) => {
    http.get({host: '127.0.0.1', port: 18443, path,
              headers: {'Accept-Encoding': 'identity'}}, r => {
      let b = ''; r.on('data', c => b += c); r.on('end', () => res(JSON.parse(b)));
    }).on('error', rej);
  });
}

const sandbox = {window: {}, document: {}, fetch: () => { throw new Error('no fetch in this test'); },
                 setTimeout, clearTimeout, console};
sandbox.global = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync('served-lib.js', 'utf8'), sandbox);
const A = sandbox.window.AowlSettings;

let fails = [];
function check(n, c, d) { console.log((c ? 'PASS ' : 'FAIL ') + n + (d !== undefined ? ' :: ' + JSON.stringify(d) : '')); if (!c) fails.push(n); }

(async () => {
  check('library exposes its documented surface',
    ['getSchema','setValue','resetKey','resetAll','matches','groupRows','controlFor','mount','replyOk']
      .every(k => typeof A[k] === 'function'));

  const rows = await get('/aowlspt/settings/aowl.uihubscale?ident=1');
  check('278 rows loaded', rows.length === 278, rows.length);

  /* search */
  const all = rows.filter(r => A.matches(r, ''));
  check('empty query matches everything', all.length === rows.length);
  const byCat = rows.filter(r => A.matches(r, 'weather'));
  check('search by CATEGORY narrows', byCat.length === 33 && byCat.every(r => r.category === 'Weather'), byCat.length);
  const two = rows.filter(r => A.matches(r, 'weather experimental'));
  check('two words are ANDed, not ORed', two.length === 11 && two.every(r => r.subcategory === 'Experimental'), two.length);
  const byDesc = rows.filter(r => A.matches(r, 'no range declared'));
  check('search reaches the DESCRIPTION', byDesc.length === 24, byDesc.length);
  const byKey = rows.filter(r => A.matches(r, 'itemremote'));
  check('search reaches the KEY, case-insensitively', byKey.length === 1 && byKey[0].key === 'itemRemote');
  check('a term in nothing matches nothing', rows.filter(r => A.matches(r, 'qqzz')).length === 0);

  /* grouping */
  const g = A.groupRows(rows);
  check('9 categories, in declaration order', g.length === 9 && g[0].name === 'General' && g[7].name === 'Diagnostics',
        g.map(x => x.name));
  check('each category has its 3 subcategories', g.every(c => c.subs.length === 3 || c.name === 'Loot' || c.name === 'Deep'),
        g.map(c => c.subs.length));

  /* ARBITRARY DEPTH, as the SERVED payload expresses it. The legacy two-level
   * grouping above is untouched -- that is the point: `path` is additive, and
   * this library`s existing consumers keep working. */
  const deepRows = rows.filter(r => (r.path || [])[0] === 'Deep');
  check('the deep rows arrive with an ordered path', deepRows.length === 12, deepRows.length);
  check('paths reach depth 5', Math.max(...deepRows.map(r => r.path.length)) === 5,
        deepRows.map(r => r.path.length));
  check('no path segment is empty anywhere in the document',
        rows.every(r => (r.path || []).every(seg => seg && seg.trim())));
  /* Sorting by the joined path makes every PREFIX a contiguous range -- the
   * invariant the native overlay`s flat item index depends on. Asserted here
   * on the payload so a schema change that breaks it is caught without a GPU. */
  const sorted = rows.filter(r => r.path).map(r => r.path.join('/')).sort();
  const contiguous = sorted.every((p, i) => {
    const pre = p.split('/').slice(0, -1).join('/');
    if (!pre) return true;
    const first = sorted.findIndex(q => q === pre || q.startsWith(pre + '/'));
    const last = sorted.length - 1 - [...sorted].reverse()
                   .findIndex(q => q === pre || q.startsWith(pre + '/'));
    return i < first || i > last || (i >= first && i <= last);
  });
  check('sorting by the joined path keeps every prefix contiguous', contiguous);
  const total = g.reduce((a, c) => a + c.subs.reduce((b, s) => b + s.rows.length, 0), 0);
  check('grouping loses no row and duplicates none', total === rows.length, total);

  /* large-enum helpers */
  const inline = A.inlineOptions(rows.find(r => r.key === 'itemInline'));
  check('inlineOptions pairs 900 ids with their labels',
        inline.length === 900 && inline[3].value.startsWith('5') && /#3$/.test(inline[3].label), inline[3]);
  check('labelForValue resolves an id to its display name',
        A.labelForValue(rows.find(r => r.key === 'itemInline'), inline[7].value) === inline[7].label);
  const noLabels = {options: ['a','b'], optionLabels: ['only one']};
  check('mismatched optionLabels fall back to the raw values, never mislabel',
        A.inlineOptions(noLabels).map(o => o.label).join() === 'a,b');

  /* the success/failure discriminator */
  check('replyOk distinguishes an array from an err object',
        A.replyOk([]) === true && A.replyOk({err: 'x', rows: []}) === false &&
        A.replyErr({err: 'x'}) === 'x' && A.replyRows({err: 'x', rows: [1]}).length === 1);

  console.log('');
  console.log(fails.length ? 'FAILED: ' + fails.join(', ') : 'ALL PASS');
  process.exit(fails.length ? 1 : 0);
})();
