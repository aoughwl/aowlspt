# The aowlspt settings UI API

There is exactly **one** settings surface. The native in-game F12 screen, the
fallback browser page at `/aowlspt/ui/page/settings` (`mods/uihub`), and any
third-party page you build all read and write the same HTTP JSON routes. None
of them contain settings logic of their own — a value's type, range, default
and current state live in one place, declared by the mod that owns the
setting, via `aowl/src/aowlspt/settings.nim`. If a UI needs something a route
does not expose, the fix is to add it to the route, not to the UI.

## Routes

| Method | Path | Returns |
|---|---|---|
| GET | `/aowlspt/settings/index` | `{"mods":[{"guid","name","count"}...]}` — every mod that has declared settings |
| GET | `/aowlspt/settings/<guid>` | `[{Setting}...]` — that mod's schema, current values folded in |
| POST | `/aowlspt/settings/<guid>` | body `{"key":"<configKey>","value":<json literal>}`; persists the edit — creating the key in `config.json` if it was never there. Reply is `[{Setting}...]` on success; on failure it is instead `{"err":"<reason>","rows":[{Setting}...]}` — an OBJECT, not an array, deliberately, so `Array.isArray(reply)` is the one-line check for "did this actually persist" |
| POST | `/aowlspt/settings/<guid>/reset` | body `{"key":"<configKey>"}` resets that one key, or an empty body `{}` resets every key this mod declares — in both cases to the value in that key's `default` field, the schema's one source of truth. Same success/failure reply shape as the write route above |
| GET | `/aowlspt/settings/spt/index` | `{"pages":[{id,label,count,done}...]}` — the read-only SPT config catalogue (`mods/settingshub`) |
| GET | `/aowlspt/settings/spt/page/<id>` | `{"settings":[...],"nested":[...]}` — one SPT config page, all `implemented:false` today |
| GET | `/aowlspt/ui/page/settings` | the settings HTML page (`mods/uihub`), for a human with a browser |
| GET | `/aowlspt/ui/lib/settings.js` | the settings CLIENT LIBRARY the page above is built out of, as `window.AowlSettings` — served `text/javascript`, uncompressed, so any page can `<script src>` it |
| GET | `<a row's optionsUrl>?q=<term>&limit=<n>` | OPTIONAL, owned by the declaring mod: `{"options":[{"value","label"}...],"matched":N}` — how a `type:"select"` row with thousands of choices is searched without shipping them in the schema |

`/aowlspt/settings/index` is an aggregation: every mod that ever called
`declareSettings` answers a broadcast (`aowlspt/settings`'s
`SettingsIndexQuery`/`SettingsIndexAnnounce`) each time the index route is hit,
so the list is always current — no separate registration step, and no mod has
to know the aggregator exists.

## The `Setting` JSON shape

One row of `GET /aowlspt/settings/<guid>`:

```json
{
  "key": "espMaxDistance",
  "label": "ESP max distance (m)",
  "type": "float",
  "default": 400.0,
  "value": 400.0,
  "min": 10.0, "max": 2000.0, "step": 10.0,
  "category": "Visuals",
  "description": "optional help text",
  "implemented": true
}
```

`type` is one of `bool | int | float | enum | string | keybind | select`.
`min`/`max`/`step` are present only when the setting declared a range;
`options` (a string array) is present for `type:"enum"` and may be present for
`type:"select"`. `implemented:false` means the value is carried and shown but
nothing acts on it yet — any UI should draw it visibly disabled/greyed rather
than omit it, so a player is told the truth instead of seeing a shorter list.

`category` groups rows into a section within one mod's schema, and the
OPTIONAL `subcategory` is one further level inside it. Neither is a separate
"declare a page" call: a mod's whole schema **is** its page. Both are emitted
only when non-empty, and both should be rendered in DECLARATION order — a mod
author orders their schema deliberately.

### The optional fields, and what a renderer owes them

Every field below is emitted **only when the mod asked for it**, so a renderer
written against the older six-type shape keeps working unchanged.

| field | on | meaning |
|---|---|---|
| `subcategory` | any row | a second grouping level inside `category` |
| `optionLabels` | `enum`/`select` | display names, exactly parallel to `options`. Emitted only when the two arrays are the same length — a mismatched labels array would silently mislabel a control, so it is dropped instead |
| `optionsUrl` | `select` | a route the UI queries as the user types, instead of (or as well as) `options` |

`type:"select"` is `enum`'s value shape — a plain string — with a different
instruction to the renderer: **do not build a `<select>`, build a searchable
typeahead**, because the choice set may be in the thousands (item ids). A
renderer that has never heard of `select` and falls through to its `enum`
branch still produces a working control from `options`; that compatibility is
why the value was kept a string rather than becoming an object.

`optionsUrl` is the shape that actually scales. The mod that owns the ids
serves it and does the searching:

```
GET <optionsUrl>?q=<term>&limit=<n>
-> {"options":[{"value":"5449016a4bdc2d6f028b456f","label":"Roubles"}, ...],
    "matched": 412}
```

`matched` is the count BEFORE `limit` was applied, so a UI can say "showing
the first 60" honestly instead of implying the list is complete. An empty `q`
means "the first n, unfiltered". `tests/uihubscale` is the reference
implementation of both ends.

## Wire transport note

The backend deflates every response by default and never sends a
`Content-Encoding` header (mirrors the real BSG server — see
`backend/aowlbackend.nim`). The native client and the overlay's own HTTP
worker both know to inflate. **Browser JS cannot** — the Fetch spec forbids a
script from ever setting `Accept-Encoding`. So a browser-based client should
append `?ident=1` to every request (works on any route, GET or POST); the
backend then sends that one response uncompressed. It changes nothing about
the JSON returned, only the bytes on the wire. `mods/uihub`'s page does this
on every call — see its `apiGet`/`apiPost`.

## Adding a page: the Nimony API

A mod declares its whole settings page in code, at load, with no HTML:

```nim
import aowlspt/settings

proc onMySettings(url, body, session: string): string =
  if body.len > 0 and applySettingFromBody(body) == Ok:
    reloadMyConfig()          # your own re-read, so the new value goes live
  result = declaredSchemaJson().text

proc onLoad(): Status =
  declareSettings(@[
    boolSetting("enabled", "Enabled", true, category = "General"),
    floatSetting("intensity", "Intensity", 1.0,
                 lo = 0.0, hi = 2.0, step = 0.05, category = "General",
                 description = "How strong the effect is"),
    enumSetting("mode", "Mode", "auto", @["auto", "manual", "off"],
                category = "General"),
    keybindSetting("toggleKey", "Toggle key", "M", category = "Keys")])
  discard serve("/aowlspt/settings/" & ModGuid, onMySettings)
  Ok
```

That is the entire contribution surface — seven builders
(`boolSetting`/`intSetting`/`floatSetting`/`enumSetting`/`stringSetting`/
`keybindSetting`/`selectSetting`), each taking optional `category`,
`subcategory`, `description` and `implemented`; one call to register them, one route that echoes
`declaredSchemaJson()` back after applying an edit. Every renderer — native
F12, the fallback browser page, or a third party's own — draws whatever
control the row's `type` calls for; the mod author never writes a line of UI
code. This is deliberately as small a surface as `declareSettings` already
was — the fallback UI and the Nimony API are the same contract, not two.

## Building your own UI on the shipped client

`mods/uihub` keeps NO private copy of any of this. Its page is a shell around
one call, and everything it can do is served at `/aowlspt/ui/lib/settings.js`
as `window.AowlSettings`. A third-party page gets the identical code path:

```html
<div id="app"></div>
<script src="/aowlspt/ui/lib/settings.js?ident=1"></script>
<script>AowlSettings.mount(document.getElementById('app'));</script>
```

`mount(el)` is the whole screen: mod list, search across one mod or all mods,
collapsible `category`/`subcategory` sections with a sidebar, a deep-linkable
hash (`#guid=<guid>&cat=<category>&q=<query>`), incremental rendering so
hundreds of rows do not all enter the DOM at once, per-row and page-level
reset, sliders for ranged numbers, and searchable typeaheads for large
enumerations.

To build something else, use the pieces instead:

| call | does |
|---|---|
| `listMods()` / `getSchema(guid)` | the two GETs, already parsed |
| `setValue(guid, key, value)` / `resetKey(guid, key)` / `resetAll(guid)` | the POSTs |
| `replyOk(r)` / `replyErr(r)` / `replyRows(r)` | tell a persisted write from a refused one — never weaken this to a truthiness check |
| `matches(row, query)` | the search predicate (every word must appear in key/label/description/category/subcategory) |
| `groupRows(rows)` | `[{name, subs:[{name, rows}]}]`, in declaration order |
| `inlineOptions(row)` / `labelForValue(row, v)` | `options` + `optionLabels` as `{value,label}` pairs |
| `controlFor(row, onSave)` | the one switch on `row.type`, as a DOM element |
| `apiGet(path)` / `apiPost(path, body)` | the transport, `?ident=1` handled |

Nothing in the library is specific to the shipped page, and nothing in the
shipped page is specific to the library — which is the point: a third-party UI
cannot drift from the one that ships, because it is running it.

## Worked example: a third-party page

A minimal standalone HTML file, not part of this repo, that lists mods, shows
one mod's settings, and writes one edit back:

```html
<!doctype html><html><body>
<select id="mods"></select>
<pre id="out"></pre>
<script>
const base = 'https://127.0.0.1:443';
async function get(p)  { return (await fetch(base+p+(p.includes('?')?'&':'?')+'ident=1')).json(); }
async function post(p,b){ return (await fetch(base+p+'?ident=1', {
  method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(b)
})).json(); }

(async () => {
  const idx = await get('/aowlspt/settings/index');
  const sel = document.getElementById('mods');
  idx.mods.forEach(m => sel.add(new Option(m.name, m.guid)));
  sel.onchange = show;
  if (idx.mods.length) show();

  async function show() {
    const guid = sel.value || idx.mods[0].guid;
    const rows = await get('/aowlspt/settings/' + guid);
    document.getElementById('out').textContent = JSON.stringify(rows, null, 2);
  }

  // Example write: flip the first bool row it finds.
  async function flipFirstBool(guid) {
    const rows = await get('/aowlspt/settings/' + guid);
    const row = rows.find(r => r.type === 'bool');
    if (!row) return;
    const updated = await post('/aowlspt/settings/' + guid,
      {key: row.key, value: !row.value});
    console.log('now', updated.find(r => r.key === row.key).value);
  }
})();
</script>
</body></html>
```

Nothing here is special to `mods/uihub` — it is the same two GET shapes and
one POST shape any consumer uses, including the native screen and the
fallback page itself.

## What talks to what

```
mod (e.g. mods/admin)
  declareSettings([...])              <- Nimony API, this doc's "Adding a page"
  serve("/aowlspt/settings/<guid>")   <- one route, GET+POST

mods/settingshub
  aggregates every mod's declaration into /aowlspt/settings/index
  + the read-only SPT catalogue under /aowlspt/settings/spt/*

mods/uihub
  serves /aowlspt/ui/page/settings — an HTML+JS page that calls the
  routes above from a browser, with no settings logic of its own

native F12 overlay (host/Aowlspt.Overlay)
  polls the same /aowlspt/settings/* routes over its own worker thread
  (aowl_ov_sync_start/take, aowl_ov_post_start/take)

third-party page (anyone's)
  same routes, any HTTP client, `?ident=1` if it is browser JS
```
