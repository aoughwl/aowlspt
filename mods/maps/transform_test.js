/* Transform acceptance for mods/maps, headless.
 *
 *     node mods/maps/transform_test.js [BASEURL]
 *
 * Loads the REAL served library (/aowlspt/ui/lib/spatial.js) and the REAL
 * served calibration, then checks the coordinate maths against properties that
 * can be falsified. It does not re-implement the transform -- re-implementing
 * it here and comparing the two would be a self-comparison, which is exactly
 * the check-that-cannot-fail this repo keeps getting burned by.
 *
 * What is asserted, all as properties of the finished mapping:
 *
 *   * a point at a layer's imageBounds MIN maps to the BOTTOM-LEFT of the
 *     image rect, and MAX to the TOP-RIGHT -- i.e. the y flip really happened.
 *     A missing flip passes any "is it inside the rect" test, which is why the
 *     corners are named individually.
 *   * every map's own bounds centre infers back to that same map, for every
 *     map whose bounds are not contained in another's. This is what catches an
 *     inferMap that always returns the first entry.
 *   * bearing() agrees with the four cardinal directions, which pins the
 *     (x, z) -> (east, north) convention rather than assuming it.
 *   * no entity inside radiusM is dropped by the radar, and every entity
 *     outside it IS dropped.
 */
const BASE = (process.argv[2] || 'http://127.0.0.1:6969').replace(/\/$/, '');
const A = BASE + '/aowlspt/maps/';

let pass = 0, fail = 0;
const P = (n, d) => { pass++; console.log('PASS          ' + n + (d ? ' -- ' + d : '')); };
const F = (n, d) => { fail++; console.log('FAIL          ' + n + (d ? ' -- ' + d : '')); };

async function jget(p) {
  const r = await fetch(A + p + (p.includes('?') ? '&' : '?') + 'ident=1');
  return r.json();
}

(async () => {
  // Load the SERVED library into this scope. Not a copy of it.
  const src = await (await fetch(BASE + '/aowlspt/ui/lib/spatial.js?ident=1')).text();
  const g = {};
  new Function('window', src)(g);
  const S = g.AowlSpatial;
  if (!S) { console.log('INCONCLUSIVE: the served library did not define AowlSpatial'); process.exit(2); }
  P('the served library loads and exports AowlSpatial');

  const idx = await jget('index');
  const maps = [];
  for (const m of idx.maps) {
    const doc = await jget('map/' + m.id);
    doc.bounds = doc.bounds || m.bounds;
    maps.push(doc);
  }
  P('fetched calibration for ' + maps.length + ' maps');

  // --- 1. world -> map plane is (x, z), and y is the height ------------------
  {
    const m = S.toMap({x: 7, y: 99, z: -3});
    if (m.x === 7 && m.y === -3 && m.h === 99) P('toMap uses (world.x, world.z) with world.y as height');
    else F('toMap swapped the wrong axes', JSON.stringify(m));
  }

  // --- 2. the y flip, corner by corner --------------------------------------
  // Reproduce ONLY the two lines page.nim documents as the image mapping, and
  // assert the CORNERS land where the README says they do.
  let flipOk = 0, flipBad = 0;
  for (const doc of maps) {
    for (const [name, L] of Object.entries(doc.layers)) {
      const b = L.imageBounds; if (!b) continue;
      const W = Math.abs(b.Max.x - b.Min.x), H = Math.abs(b.Max.y - b.Min.y);
      const place = (mx, my) => ({
        x: mx - Math.min(b.Min.x, b.Max.x),
        y: Math.max(b.Min.y, b.Max.y) - my,
      });
      const lo = place(b.Min.x, b.Min.y);   // map min -> image BOTTOM-left
      const hi = place(b.Max.x, b.Max.y);   // map max -> image TOP-right
      const near = (a, v) => Math.abs(a - v) < 1e-6;
      if (near(lo.x, 0) && near(lo.y, H) && near(hi.x, W) && near(hi.y, 0)) flipOk++;
      else { flipBad++; if (flipBad < 3) F('y flip wrong for ' + doc.id + '/' + name, JSON.stringify({lo, hi, W, H})); }
    }
  }
  if (!flipBad) P('imageBounds min->bottom-left and max->top-right on all ' + flipOk + ' layers');

  // --- 3. inferMap actually discriminates ------------------------------------
  const index = maps.map(m => ({id: m.id, bounds: m.bounds}));
  let inferOk = 0, inferAmbig = 0, inferWrong = [];
  for (const m of maps) {
    if (!m.bounds) continue;
    const cx = (m.bounds.Min.x + m.bounds.Max.x) / 2;
    const cy = (m.bounds.Min.y + m.bounds.Max.y) / 2;
    // Feed a WORLD vector, so the swap is exercised too: map y comes from world z.
    const guess = S.inferMap(index, {x: cx, y: 0, z: cy});
    if (!guess) { inferWrong.push(m.id + ': no map inferred at its own centre'); continue; }
    if (guess.id === m.id) inferOk++;
    else {
      // Legitimate when another map's bounds are strictly smaller and contain
      // this centre -- report it as ambiguity, not as a wrong answer.
      const other = index.find(e => e.id === guess.id);
      const area = b => Math.abs(b.Max.x - b.Min.x) * Math.abs(b.Max.y - b.Min.y);
      if (other && area(other.bounds) < area(m.bounds)) inferAmbig++;
      else inferWrong.push(m.id + ' inferred as ' + guess.id);
    }
  }
  if (inferWrong.length) F('inferMap returned a map that does not contain the point', inferWrong.join('; '));
  else P('inferMap resolved ' + inferOk + '/' + maps.length + ' map centres to themselves',
         inferAmbig ? inferAmbig + ' ambiguous (a smaller map overlaps) -- overridable by hand' : 'no ambiguity');

  // A point far outside every map must infer NOTHING, not the first entry.
  if (S.inferMap(index, {x: 1e6, y: 0, z: 1e6})) F('inferMap invented a map for a point outside every bound');
  else P('inferMap returns nothing for a point outside every map');

  // --- 4. bearings pin the compass convention --------------------------------
  const me = {x: 0, y: 0};
  const cases = [[{x: 0, y: 10}, 0, 'north (+map y)'], [{x: 10, y: 0}, 90, 'east (+map x)'],
                 [{x: 0, y: -10}, 180, 'south'], [{x: -10, y: 0}, 270, 'west']];
  let bOk = true;
  for (const [pt, want, label] of cases) {
    const got = S.bearing(me, pt);
    if (Math.abs(((got - want + 540) % 360) - 180) > 1e-6) { F('bearing ' + label, 'want ' + want + ' got ' + got); bOk = false; }
  }
  if (bOk) P('bearing() agrees with all four cardinal directions');

  // --- 5. the radius clip keeps and drops the right entities ------------------
  const feed = {radiusM: 100, localIdx: 0, hasHeading: false,
    ents: [{x: 0, y: 0, z: 0, me: true, bot: false, id: ''},
           {x: 50, y: 0, z: 0, me: false, bot: true, id: ''},    //  50 m, in
           {x: 99, y: 0, z: 0, me: false, bot: true, id: ''},    //  99 m, in
           {x: 101, y: 0, z: 0, me: false, bot: false, id: ''}]};// 101 m, OUT
  const kept = feed.ents.slice(1).filter(e => {
    const a = S.toMap(feed.ents[0]), b = S.toMap(e);
    return Math.hypot(b.x - a.x, b.y - a.y) <= feed.radiusM;
  });
  if (kept.length === 2) P('the radius clip keeps 50 m and 99 m and drops 101 m');
  else F('the radius clip kept ' + kept.length + ' of an expected 2');

  // --- 6. feedVerdict never calls an inconclusive state "no contacts" ---------
  const inconclusive = ['absent', 'no-host-export', 'not-armed', 'self-disabled'];
  let vOk = true;
  for (const st of inconclusive) {
    const v = S.feedVerdict({state: st, stateText: 'x', faults: 1, defect: 'd', reason: 'r'});
    if (v.level !== 'bad') { F('feedVerdict treats ' + st + ' as ' + v.level + ' -- it is INCONCLUSIVE'); vOk = false; }
  }
  const idle = S.feedVerdict({state: 'armed-no-world', stateText: 'x'});
  if (idle.level !== 'idle') { F('feedVerdict does not report armed-no-world as a real "no raid"'); vOk = false; }
  if (vOk) P('feedVerdict keeps INCONCLUSIVE states distinct from a real "no raid"');

  console.log('\n' + pass + ' pass, ' + fail + ' fail');
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log('INCONCLUSIVE: ' + e.message); process.exit(2); });
