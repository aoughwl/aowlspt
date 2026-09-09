## benchbackend -- a load generator for `aowlspt-backend`, over the real wire.
##
##     benchbackend --backend <aowlspt-backend.exe> --root <stage>
##                  --mod <tarkov.dll> [--items 3000] [--rounds 20]
##
## Why a tool of its own rather than a timing flag in `--selftest`: the numbers
## that matter are the ones a *client* sees, which means going through sockets,
## HTTP framing and zlib exactly as the game does. Anything measured inside the
## server would miss the two costs that turned out to dominate -- deflating a
## multi-megabyte body per request, and copying it a byte at a time on the way
## out.
##
## The mix is the client's, not a synthetic uniform one:
##
##   * the big static tables (`/client/items`, `/client/globals`,
##     `/client/locale/en`, the handbook) -- a handful of requests carrying
##     nearly all of the bytes, all served out of the database unchanged;
##   * a burst of `/client/game/profile/items/moving` -- the most frequent
##     endpoint in a session, small bodies, real work and a profile write;
##   * a profile read and a keepalive -- the small-body floor, which is where
##     per-connection overhead shows up undisguised.
##
## The database is generated rather than shipped: a real Tarkov dump is tens of
## megabytes and cannot live in a repo, and a benchmark against the 1.8 KB test
## fixture measures nothing at all -- every cost here scales with document size.
## `--items N` sets the scale; the shape (ids, `_props`, locale strings) matches
## what the emulator actually reads.

import std/[strutils, syncio, cmdline, algorithm]
import aowlsptinstall/[winfs, log]
import wire

{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_shim.h" """.}
{.emit: """#include "aowlspt_net.h" """.}
{.emit: """#include "aowlspt_inject.h" """.}

{.emit: """
/* QueryPerformanceCounter, not GetTickCount64. An item move answers in well
 * under a millisecond once the obvious costs are gone, and a millisecond clock
 * reports that as either 0 or 1 -- which is not a measurement, it is a coin
 * flip. */
static int64_t aowl_bench_qpc(void) {
  LARGE_INTEGER v; QueryPerformanceCounter(&v); return (int64_t)v.QuadPart;
}
static int64_t aowl_bench_qpf(void) {
  LARGE_INTEGER v; QueryPerformanceFrequency(&v); return (int64_t)v.QuadPart;
}
""".}

proc cSpawn(exe, workDir, cmdLine: cstring): uint64 {.
  importc: "aowl_spawn", nodecl.}
proc cSpawnKill(h: uint64) {.importc: "aowl_spawn_kill", nodecl.}
proc cSleepMs(ms: int32) {.importc: "aowl_sys_sleep", nodecl.}
proc cQpc(): int64 {.importc: "aowl_bench_qpc", nodecl.}
proc cQpf(): int64 {.importc: "aowl_bench_qpf", nodecl.}

const
  Usage = """
benchbackend -- drive aowlspt-backend under load and report the numbers

  benchbackend --backend PATH --root PATH --mod PATH [options]

  --backend PATH   aowlspt-backend.exe
  --root PATH      scratch install to build and serve from (wiped)
  --mod PATH       the emulator dll (mods/tarkov/bin/tarkov.dll)
  --config PATH    its config.json, copied beside the dll
  --port N         port to serve on (default 6977)
  --items N        generated item templates (default 3000)
  --rounds N       measured rounds of the mix (default 20)
  --warmup N       unmeasured rounds first (default 3)
  --moves N        item moves per round (default 25)
  --label TEXT     printed with the results, so two runs can be told apart
  --keep-db        reuse an existing db.json in --root rather than regenerating
  --keepalive      reuse one connection for every request, as the game does
  --perf           ask the backend for its per-phase breakdown and print it
  --floor N        fail (exit 1) if the run is under N requests/second
  -h, --help       this
"""
  Session = "aaaaaaaaaaaaaaaaaaaaaaaa"

  # The templates the emulator itself needs to boot a profile: the stash it
  # puts the player's grid in, the roubles it starts them with, and a rifle for
  # the trader's assort. Generated items are additional to these, never instead
  # of them -- a benchmark that cannot create a profile measures the error path.
  TplRoubles = "5449016a4bdc2d6f028b456f"
  TplRifle = "5644bd2b4bdc2d3b4c8b4572"

var gPort = 6977
var gQpf = 1'i64

# One connection reused across requests, when `--keepalive` is on. Kept as a
# module-level variable rather than threaded through every call site because
# `mixRound` cannot close over a local -- nimony has no closures over an
# enclosing scope.
var gKeepAlive = false
var gPerf = false
var gConn = Conn(sock: 0'u64, buf: @[], have: 0, port: 6977)

proc nowUs(): int64 =
  ## Microseconds. The division is done per reading rather than at the end so a
  ## long run cannot overflow the multiply.
  let t = cQpc()
  result = (t div gQpf) * 1000000'i64 + ((t mod gQpf) * 1000000'i64) div gQpf

# --------------------------------------------------------------- samples

type
  Bucket = object
    name: string
    us: seq[int64]
    ttfb: seq[int64]
    bytes: int64

var gBuckets: seq[Bucket] = @[]

proc cmpI64(x, y: int64): int =
  if x < y: -1
  elif x > y: 1
  else: 0

proc record(name: string; us, ttfb: int64; bytes: int) =
  for i in 0 ..< gBuckets.len:
    if gBuckets[i].name == name:
      gBuckets[i].us.add us
      if ttfb > 0'i64: gBuckets[i].ttfb.add ttfb
      gBuckets[i].bytes = gBuckets[i].bytes + int64(bytes)
      return
  var b = Bucket(name: name, us: @[], ttfb: @[], bytes: int64(bytes))
  b.us.add us
  if ttfb > 0'i64: b.ttfb.add ttfb
  gBuckets.add b

proc resetSamples() =
  gBuckets = @[]

proc pad(s: string; width: int): string =
  result = s
  while result.len < width:
    result.add ' '

proc lpad(s: string; width: int): string =
  result = ""
  var i = s.len
  while i < width:
    result.add ' '
    inc i
  result.add s

proc msText(us: int64): string =
  ## Microseconds as milliseconds with three decimals, without touching
  ## `formatFloat` -- there is nothing to round and integer text cannot lie.
  var v = us
  var sign = ""
  if v < 0:
    sign = "-"
    v = 0'i64 - v
  let whole = v div 1000'i64
  let frac = v mod 1000'i64
  var f = $frac
  while f.len < 3:
    f = "0" & f
  result = sign & $whole & "." & f

proc pct(s: seq[int64]; p: int): int64 =
  ## Nearest-rank against an already-sorted sample. With a few hundred samples
  ## an interpolated percentile is precision the sample size does not support.
  if s.len == 0:
    return 0
  var idx = (s.len * p) div 100
  if idx >= s.len: idx = s.len - 1
  result = s[idx]

# --------------------------------------------------------------- the mix

proc call(path, body: string): Response =
  if gKeepAlive:
    result = requestOn(gConn, path, body, Session)
  else:
    result = request(gPort, path, body, Session)

var gBadRequests = 0
var gBadFirst = ""

proc healthy(name: string; r: Response): bool =
  ## Whether a request in the mix was actually served.
  ##
  ## This tool measures throughput, and until now it measured it with
  ## `discard timed(...)` -- every response thrown away unread. A 404 is the
  ## *fastest* thing this server can produce, so a stage where the emulator did
  ## not load answers `{"err":"no route"}` to five of the seven endpoints in the
  ## mix, reports a higher requests/second than a working one, and clears
  ## `--floor` comfortably. A performance gate that a broken server passes more
  ## easily than a working one is worse than no gate, so every request is now
  ## looked at, and one that was not served is counted.
  result = r.ok and r.body.len > 0 and
           find(r.body, "\"err\":\"no route\"") < 0 and
           (find(r.body, "\"err\":0") >= 0 or find(r.body, "OK") >= 0)
  if not result:
    inc gBadRequests
    if gBadFirst.len == 0:
      var seen = r.body
      if seen.len > 140: seen = seen.substr(0, 139) & "..."
      gBadFirst = name & " -> " & (if r.error.len > 0: r.error else: seen)

proc timed(name, path, body: string): Response =
  let t0 = nowUs()
  let r = call(path, body)
  let t1 = nowUs()
  record(name, t1 - t0, r.ttfbUs, r.body.len)
  discard healthy(name, r)
  result = r

proc jsonText(body, key: string): string =
  let at = find(body, "\"" & key & "\":\"")
  if at < 0:
    return ""
  var i = at + key.len + 4
  result = ""
  while i < body.len and body[i] != '"':
    result.add body[i]
    inc i

proc idOfTemplate(body, tpl: string): string =
  ## The `_id` of the item carrying `_tpl`, found by scanning *back* -- an
  ## item's own id precedes its template in the document, so reading forward
  ## finds the next item's id. Same reasoning as `emutest`.
  let at = find(body, "\"_tpl\":\"" & tpl & "\"")
  if at < 0:
    return ""
  var i = at
  while i > 0:
    if i + 7 < body.len and body.substr(i, i + 6) == "\"_id\":\"":
      var k = i + 7
      result = ""
      while k < body.len and body[k] != '"':
        result.add body[k]
        inc k
      return result
    dec i
  result = ""

proc moveBody(itemId: string; x, y: int): string =
  ## A drag of one stack to a stash cell. The client's most frequent write, and
  ## the one endpoint here that reads the database *and* saves a profile.
  result = "{\"data\":[{\"Action\":\"Move\",\"item\":\"" & itemId &
           "\",\"to\":{\"id\":\"hideout\",\"container\":\"hideout\"," &
           "\"location\":{\"x\":" & $x & ",\"y\":" & $y &
           ",\"r\":\"Horizontal\"}}}],\"tm\":2}"

proc mixRound(itemId: string; moves: int; measure: bool) =
  ## One pass of the client's mix. `measure` is false during warmup so the
  ## first-touch costs -- the store's first write, the first page fault on a
  ## multi-megabyte response -- do not land in the percentiles.
  if measure:
    discard timed("items", "/client/items", "")
    discard timed("globals", "/client/globals", "")
    discard timed("locale/en", "/client/locale/en", "")
    discard timed("handbook", "/client/handbook/templates", "")
    discard timed("profile/list", "/client/game/profile/list", "")
    discard timed("keepalive", "/client/game/keepalive", "")
    for i in 0 ..< moves:
      discard timed("items/moving", "/client/game/profile/items/moving",
                    moveBody(itemId, 1 + (i mod 8), i mod 6))
  else:
    discard healthy("items", call("/client/items", ""))
    discard healthy("globals", call("/client/globals", ""))
    discard healthy("locale/en", call("/client/locale/en", ""))
    discard healthy("handbook", call("/client/handbook/templates", ""))
    discard healthy("profile/list", call("/client/game/profile/list", ""))
    discard healthy("keepalive", call("/client/game/keepalive", ""))
    for i in 0 ..< moves:
      discard healthy("items/moving",
                      call("/client/game/profile/items/moving",
                           moveBody(itemId, 1 + (i mod 8), i mod 6)))

# --------------------------------------------------------------- database

proc hexId(n: int): string =
  ## A 24-character MongoId from a counter. Deterministic on purpose: two runs
  ## of the benchmark must hit the same paths, or an index being measured is
  ## being measured against a different workload each time.
  const digits = "0123456789abcdef"
  result = ""
  var v = uint64(n) * 2654435761'u64 + 1'u64
  var i = 0
  while i < 24:
    result.add digits[int((v shr uint(4 * (i mod 16))) and 0xF'u64)]
    if i == 15:
      v = v * 6364136223846793005'u64 + 1442695040888963407'u64
    inc i

proc itemBody(id: string; n: int): string =
  ## One `templates.items` entry, shaped like the real thing: the handful of
  ## `_props` the emulator reads, plus the long tail it never looks at. The
  ## tail is not filler for its own sake -- it is what makes the document the
  ## size a real dump is, and every cost measured here scales with that size.
  var s = "\"" & id & "\":{\"_id\":\"" & id & "\",\"_name\":\"bench_item_" &
          $n & "\",\"_parent\":\"5447e1d04bdc2dff2f8b4567\",\"_type\":\"Item\","
  s.add "\"_props\":{\"Name\":\"Bench item " & $n & "\","
  s.add "\"ShortName\":\"BI" & $n & "\","
  s.add "\"Description\":\"A generated template used only by benchbackend.\","
  s.add "\"Weight\":" & $(n mod 40) & ".1" & $(n mod 10) & ","
  s.add "\"Width\":" & $(1 + (n mod 4)) & ",\"Height\":" & $(1 + (n mod 3)) & ","
  s.add "\"StackMaxSize\":" & $(1 + (n mod 60)) & ","
  s.add "\"Rarity\":\"Common\",\"SpawnChance\":" & $(n mod 100) & ","
  s.add "\"CreditsPrice\":" & $(100 + n * 7) & ",\"ItemSound\":\"gear_generic\","
  s.add "\"Prefab\":{\"path\":\"assets/content/items/bench/item_" & $n &
        ".bundle\",\"rcid\":\"\"},"
  s.add "\"UsePrefab\":{\"path\":\"\",\"rcid\":\"\"},"
  s.add "\"BackgroundColor\":\"blue\",\"ExtraSizeLeft\":0,\"ExtraSizeRight\":0,"
  s.add "\"ExtraSizeUp\":0,\"ExtraSizeDown\":0,\"ExtraSizeForceAdd\":false,"
  s.add "\"MergesWithChildren\":false,\"CanSellOnRagfair\":true,"
  s.add "\"CanRequireOnRagfair\":false,\"ConflictingItems\":[],"
  s.add "\"Unlootable\":false,\"UnlootableFromSlot\":\"FirstPrimaryWeapon\","
  s.add "\"UnlootableFromSide\":[],\"ChangePriceCoef\":1,"
  s.add "\"FixedPrice\":false,\"Unbuyable\":false,\"IsUnbuyable\":false,"
  s.add "\"IsUngivable\":false,\"IsLockedafterEquip\":false,"
  s.add "\"QuestItem\":false,\"LootExperience\":20,\"ExamineExperience\":4,"
  s.add "\"HideEntrails\":false,\"RepairCost\":0,\"RepairSpeed\":0,"
  s.add "\"ExamineTime\":1,\"IsAlwaysAvailableForInsurance\":false,"
  s.add "\"DiscardLimit\":-1,\"DiscardingBlock\":false,\"DropSoundType\":\"None\","
  s.add "\"RagFairCommissionModifier\":1,\"InsuranceDisabled\":false,"
  s.add "\"Grids\":[],\"Slots\":[],\"Cartridges\":[],"
  s.add "\"Chambers\":[],\"Prefabs\":[],\"Effects_Health\":{},"
  s.add "\"Effects_Damage\":{},\"Effects_Speed\":{},"
  s.add "\"StackMinRandom\":1,\"StackMaxRandom\":" & $(1 + (n mod 5)) & ","
  s.add "\"medUseTime\":0,\"knifeHitDelay\":0,"
  s.add "\"Tags\":[\"bench\",\"generated\",\"" & $(n mod 17) & "\"]}}"
  result = s

proc buildDb(items: int): string =
  ## The generated document. Written once and read by every request after that,
  ## so this is deliberately not a fast path -- clarity beats speed here.
  var s = ""
  s.add "{\"traders\":{\"54cb50c76803fa8b248b4571\":{\"base\":{"
  s.add "\"_id\":\"54cb50c76803fa8b248b4571\",\"nickname\":\"Prapor\","
  s.add "\"currency\":\"RUB\",\"unlockedByDefault\":true},\"assort\":{"
  s.add "\"items\":[{\"_id\":\"aaaaaaaaaaaaaaaaaaaaaaa1\",\"_tpl\":\"" &
        TplRifle & "\",\"parentId\":\"hideout\",\"slotId\":\"hideout\"," &
        "\"upd\":{\"StackObjectsCount\":10}}],"
  s.add "\"barter_scheme\":{\"aaaaaaaaaaaaaaaaaaaaaaa1\":[[{\"_tpl\":\"" &
        TplRoubles & "\",\"count\":25000}]]},"
  s.add "\"loyal_level_items\":{\"aaaaaaaaaaaaaaaaaaaaaaa1\":1}}}},"

  s.add "\"templates\":{\"items\":{"
  s.add "\"" & TplRoubles & "\":{\"_id\":\"" & TplRoubles &
        "\",\"_props\":{\"Name\":\"Roubles\",\"Width\":1,\"Height\":1," &
        "\"StackMaxSize\":500000}},"
  s.add "\"" & TplRifle & "\":{\"_id\":\"" & TplRifle &
        "\",\"_props\":{\"Name\":\"AK-74N\",\"Width\":4,\"Height\":2," &
        "\"StackMaxSize\":1}},"
  s.add "\"5811ce572459770cba1a34ea\":{\"_id\":\"5811ce572459770cba1a34ea\"," &
        "\"_props\":{\"Name\":\"Stash 10x68\",\"Grids\":[{\"_props\":" &
        "{\"cellsH\":10,\"cellsV\":68}}]}}"
  var n = 0
  while n < items:
    s.add ","
    s.add itemBody(hexId(n), n)
    inc n
  s.add "},"

  # The handbook: one entry per generated item, which is what makes anything
  # priceable and what the insurance quote reads.
  s.add "\"handbook\":{\"Categories\":[],\"Items\":["
  s.add "{\"Id\":\"" & TplRifle & "\",\"ParentId\":" &
        "\"5b5f78dc86f77409407a7f8e\",\"Price\":22000}"
  n = 0
  while n < items:
    s.add ",{\"Id\":\"" & hexId(n) & "\",\"ParentId\":" &
          "\"5b5f78dc86f77409407a7f8e\",\"Price\":" & $(100 + n * 7) & "}"
    inc n
  s.add "]},"

  # No `customization` key at all, and the difference between that and an empty
  # one is the whole reason this line has a comment.
  #
  # The emulator's load-time self-check runs its default-appearance validation
  # only when the database *has* a customisation table: with none it skips, with
  # an empty one it looks up ten default ids, finds none of them, declares "this
  # build fails its own arithmetic" and refuses to serve. This tool wrote
  # `"customization":{}`, so the emulator came up, logged twelve errors, listened
  # on the port and answered nothing -- and every run of this benchmark died at
  # "the backend never answered /client/game/config", including the one in
  # `aowl test`. A synthetic database has no business asserting anything about
  # appearance, so it declares no table rather than an empty one.
  s.add "\"quests\":{},\"achievements\":[]},"

  # `globals` is one large object in a real dump. Its shape does not matter to
  # anything measured here; its size does.
  s.add "\"globals\":{\"config\":{\"content\":{\"ip\":\"\",\"port\":0},"
  s.add "\"BaseLoadTime\":1,\"BaseUnloadTime\":1,\"BaseCheckTime\":1,"
  s.add "\"Customization\":{\"SavageHead\":[],\"SavageBody\":[]},"
  s.add "\"exp\":{\"heal\":{\"expForHeal\":1,\"expForHydration\":1}}},"
  s.add "\"bot_presets\":["
  n = 0
  let presets = items div 4
  while n < presets:
    if n > 0: s.add ","
    s.add "{\"Role\":\"bench" & $n & "\",\"BotDifficulty\":\"normal\"," &
          "\"VisibleAngle\":180,\"VisibleDistance\":120," &
          "\"ScatteringPerMeter\":0.06,\"HearingSense\":4," &
          "\"MaxAggroDistance\":200,\"Chance\":50,\"ShotTimePause\":0.3," &
          "\"Comment\":\"a generated preset that exists to give globals the " &
          "size a real dump has\"}"
    inc n
  s.add "]},"

  # Locales: three strings per item, which is what the real table holds and
  # what makes `/client/locale/en` one of the largest bodies the server sends.
  s.add "\"locales\":{\"global\":{\"en\":{"
  n = 0
  while n < items:
    if n > 0: s.add ","
    let id = hexId(n)
    s.add "\"" & id & " Name\":\"Bench item " & $n & "\","
    s.add "\"" & id & " ShortName\":\"BI" & $n & "\","
    s.add "\"" & id & " Description\":\"A generated locale string, long " &
          "enough that the locale table is the size it is in a live dump.\""
    inc n
  s.add "}},\"menu\":{\"en\":{\"MainMenu\":\"Main menu\"}}},"

  s.add "\"hideout\":{\"areas\":[{\"type\":3,\"enabled\":true,\"stages\":" &
        "{\"1\":{\"constructionTime\":0,\"requirements\":[]}}}]},"
  s.add "\"locations\":{},\"settings\":{\"config\":{\"AudioSettings\":{}}}}"
  result = s

# --------------------------------------------------------------- driving

proc waitForBackend(tries: int): bool =
  var i = 0
  while i < tries:
    let r = call("/client/game/config", "")
    if r.ok and r.contains("\"err\":0"):
      return true
    cSleepMs(200'i32)
    inc i
  result = false

proc startBackend(exe, root: string): uint64 =
  var e = exe
  var w = root
  var c = "\"" & exe & "\" --root \"" & root & "\" --port " & $gPort
  if gPerf:
    # The backend writes its breakdown to `<root>/perf.txt` once a second as
    # well as at exit, because this tool kills it rather than asking it to
    # stop -- a report printed at exit is a report nobody ever sees.
    c.add " --perf"
  result = cSpawn(toCString(e), toCString(w), toCString(c))

proc reportLine(b: Bucket) =
  let s = sorted(b.us, cmpI64)
  var total = 0'i64
  for v in b.us:
    total = total + v
  let mean = total div int64(b.us.len)
  var row = pad(b.name, 15)
  row.add lpad($b.us.len, 6)
  row.add lpad(msText(mean), 11)
  row.add lpad(msText(pct(s, 50)), 11)
  row.add lpad(msText(pct(s, 95)), 11)
  row.add lpad(msText(pct(s, 99)), 11)
  row.add lpad(msText(s[s.len - 1]), 11)
  var ttfbMean = 0'i64
  if b.ttfb.len > 0:
    var tt = 0'i64
    for v in b.ttfb:
      tt = tt + v
    ttfbMean = tt div int64(b.ttfb.len)
  row.add lpad(msText(ttfbMean), 11)
  row.add lpad($(b.bytes div int64(b.us.len) div 1024) & "K", 9)
  line row

proc served(name, path, body, needle: string; minBytes: int): bool =
  ## One endpoint of the mix, asked once and *read*, before anything is timed.
  ##
  ## `healthy` catches a refusal; this catches the subtler half -- an endpoint
  ## that answers `err:0` out of an empty table. The needle is something only a
  ## real answer carries: an id out of the database this run generated, the uid
  ## of the profile it created. Without it a server with no database in it
  ## serves seven tiny bodies very quickly and the report calls that throughput.
  ## `minBytes` is the other half of it: an emulator serving an *empty* table
  ## answers `err:0` in forty bytes, and forty-byte answers are the fastest
  ## thing this benchmark can be handed.
  let r = call(path, body)
  let good = healthy(name, r) and find(r.body, needle) >= 0 and
             r.body.len >= minBytes
  if good:
    line "  ok    " & pad(name, 14) & lpad($r.body.len & " bytes", 14)
  else:
    var seen = r.body
    if seen.len > 140: seen = seen.substr(0, 139) & "..."
    err name & " (" & path & ") is not serving this stage: " &
        (if r.error.len > 0: r.error else: seen)
    if r.ok and find(r.body, needle) < 0:
      note "  it answered, and its answer does not contain " & needle
    if r.ok and r.body.len < minBytes:
      note "  it answered in " & $r.body.len & " bytes; anything under " &
           $minBytes & " is an empty table, not a database"
  result = good

var gRate = 0'i64

proc report(label: string; wallUs: int64) =
  heading "Results" & (if label.len > 0: " -- " & label else: "")
  # `ttfb` is time to the first byte of the answer: the server's share. The
  # difference between it and `mean` is transfer and this process's own
  # `inflate`, which on the biggest tables is most of the number and is not
  # something the server can be blamed for or fix.
  line pad("endpoint", 15) & lpad("n", 6) & lpad("mean", 11) &
       lpad("p50", 11) & lpad("p95", 11) & lpad("p99", 11) &
       lpad("max", 11) & lpad("ttfb", 11) & lpad("body", 9)
  var requests = 0
  var bytes = 0'i64
  for b in gBuckets:
    reportLine(b)
    requests = requests + b.us.len
    bytes = bytes + b.bytes
  line ""
  line "  " & $requests & " requests in " & msText(wallUs) & " ms"
  if wallUs > 0:
    gRate = (int64(requests) * 1000000'i64) div wallUs
    line "  " & $gRate & " requests/second"
    line "  " & $((bytes * 1000000'i64) div wallUs div 1048576'i64) &
         " MiB/second of response body (uncompressed)"

proc main(): int =
  var root = ""
  var backend = ""
  var modDll = ""
  var modConfig = ""
  var label = ""
  var items = 3000
  var rounds = 20
  var warmup = 3
  var moves = 25
  var floor1 = 0
  var keepDb = false
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--root":
      inc i
      if i <= n: root = paramStr(i)
    elif a == "--backend":
      inc i
      if i <= n: backend = paramStr(i)
    elif a == "--mod":
      inc i
      if i <= n: modDll = paramStr(i)
    elif a == "--config":
      inc i
      if i <= n: modConfig = paramStr(i)
    elif a == "--label":
      inc i
      if i <= n: label = paramStr(i)
    elif a == "--port" or a == "--items" or a == "--rounds" or
         a == "--warmup" or a == "--moves" or a == "--floor":
      inc i
      var v = 0
      var any = false
      if i <= n:
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            any = true
      if any:
        if a == "--port": gPort = v
        elif a == "--items": items = v
        elif a == "--rounds": rounds = v
        elif a == "--warmup": warmup = v
        elif a == "--floor": floor1 = v
        else: moves = v
    elif a == "--keep-db":
      keepDb = true
    elif a == "--keepalive":
      gKeepAlive = true
    elif a == "--perf":
      gPerf = true
    elif a == "--help" or a == "-h":
      echo Usage
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  if root.len == 0 or backend.len == 0 or modDll.len == 0:
    echo Usage
    return 1
  if not fileExists(backend):
    err "no backend at " & backend
    return 1
  if not fileExists(modDll):
    err "no mod at " & modDll
    return 1

  # Absolute, always. The backend is spawned with its working directory set to
  # the root, so a relative `--root` would be resolved a second time against
  # itself and the server would come up in a directory that has no mods in it.
  root = absolutePathOf(root)
  backend = absolutePathOf(backend)
  modDll = absolutePathOf(modDll)
  if modConfig.len > 0: modConfig = absolutePathOf(modConfig)

  gQpf = cQpf()
  if gQpf <= 0'i64:
    err "no performance counter"
    return 1

  heading "Staging"
  let dbPath = joinPath(root, "db.json")
  var dbGenerated = true
  if keepDb and fileExists(dbPath):
    line "  db      reused"
    dbGenerated = false
  else:
    discard winfs.removeTree(root)
    let db = buildDb(items)
    discard ensureDir(root)
    discard writeTextFile(dbPath, db)
    line "  db      " & $(db.len div 1048576) & " MiB, " & $items &
         " item templates"
  # The store is wiped even when the database is reused: a run that starts with
  # the profiles of the previous one measures a different profile document each
  # time, and the item-move path is exactly the one that reads it.
  discard winfs.removeTree(joinPath(root, "store"))
  discard ensureDir(joinPath(root, "mods\\tarkov"))
  discard copyFileAt(modDll, joinPath(root, "mods\\tarkov\\tarkov.dll"))
  if modConfig.len > 0 and fileExists(modConfig):
    discard copyFileAt(modConfig, joinPath(root, "mods\\tarkov\\config.json"))
  line "  root    " & root
  line "  port    " & $gPort
  line "  conn    " & (if gKeepAlive: "one, kept alive" else: "one per request")

  discard cNetStartup()
  gConn = Conn(sock: 0'u64, buf: @[], have: 0, port: gPort)

  let bootStart = nowUs()
  let server = startBackend(backend, root)
  if server == 0'u64:
    err "could not start the backend"
    return 1
  if not waitForBackend(300):
    err "the backend never answered /client/game/config"
    cSpawnKill(server)
    return 1
  let bootUs = nowUs() - bootStart
  ok "the backend came up in " & msText(bootUs) &
     " ms (process start to first answer, database load included)"

  # A profile, so the item-move burst has something to move. Not measured: it
  # happens once in a session, and it is not what this tool is about.
  let created = call("/client/game/profile/create",
                     "{\"nickname\":\"BenchRunner\",\"side\":\"Usec\"," &
                     "\"headId\":\"x\"}")
  let uid = jsonText(created.body, "uid")
  if uid.len != 24:
    err "could not create a profile: " & created.body
    cSpawnKill(server)
    return 1
  discard call("/client/game/profile/select", "{\"uid\":\"" & uid & "\"}")
  let listed = call("/client/game/profile/list", "")
  let moneyId = idOfTemplate(listed.body, TplRoubles)
  if moneyId.len != 24:
    err "the new profile has no roubles to move"
    cSpawnKill(server)
    return 1
  ok "profile " & uid & " ready"

  heading "The mix is being served"
  # Asserted, once, before a single number is measured. Everything below this
  # point is `discard`-ed on purpose -- reading a response inside the timing
  # loop would time the reading -- so this is the only place that establishes
  # the requests being counted are requests that were answered.
  var unserved = 0
  # `hexId(0)` is only in the database when this run generated it. With
  # `--keep-db` against somebody else's file the weaker needle is the honest
  # one: it still fails on a refusal and on an empty table.
  let probe0 = if dbGenerated: hexId(0) else: "_props"
  if not served("items", "/client/items", "", probe0, 1024): inc unserved
  if not served("globals", "/client/globals", "", "\"err\":0", 64):
    inc unserved
  if not served("locale/en", "/client/locale/en", "",
                (if dbGenerated: hexId(0) & " Name" else: " Name"), 1024):
    inc unserved
  if not served("handbook", "/client/handbook/templates", "",
                (if dbGenerated: hexId(0) else: "\"Id\""), 512):
    inc unserved
  if not served("profile/list", "/client/game/profile/list", "", uid, 200):
    inc unserved
  if not served("keepalive", "/client/game/keepalive", "", "OK", 2):
    inc unserved
  if not served("items/moving", "/client/game/profile/items/moving",
                moveBody(moneyId, 1, 1), "\"err\":0", 8):
    inc unserved
  if unserved > 0:
    err $unserved & " of the 7 endpoints in the mix are not served by this " &
        "stage. The rate below would be a measurement of refusals, which are " &
        "faster than answers -- so it would read as a better result than a " &
        "working server."
    cSpawnKill(server)
    return 1

  heading "Warmup"
  var w = 0
  while w < warmup:
    mixRound(moneyId, moves, false)
    inc w
  line "  " & $warmup & " rounds"

  heading "Measuring"
  resetSamples()
  # The counters too: what matters is whether the *measured* rounds were served,
  # and a warmup that stumbled on a cold disk should not be what fails the run.
  gBadRequests = 0
  gBadFirst = ""
  let t0 = nowUs()
  var r = 0
  while r < rounds:
    mixRound(moneyId, moves, true)
    inc r
  let wall = nowUs() - t0
  line "  " & $rounds & " rounds of " & $(6 + moves) & " requests"

  report(label, wall)

  if gPerf:
    # Read before the process is killed: the file is rewritten once a second
    # and the last write may be up to that far behind.
    cSleepMs(1200'i32)
    var text = ""
    if readTextFile(joinPath(root, "perf.txt"), text):
      heading "Server phases"
      for l in splitLines(text):
        if l.len > 0:
          line l
    else:
      err "the backend wrote no perf.txt; was it built with --perf support?"

  cSpawnKill(server)

  # Before the floor, and it fails the run whether or not a floor was asked for.
  # A rate computed over requests the server refused is not a slow number, it is
  # a wrong one, and it is wrong in the flattering direction.
  let measured = rounds * (6 + moves)
  if gBadRequests > 0:
    err $gBadRequests & " of " & $measured & " measured requests were not " &
        "served; the numbers above are not a throughput measurement"
    line "  first one: " & gBadFirst
    return 1
  ok "all " & $measured & " measured requests were served"

  if floor1 > 0:
    # The gate. A throughput claim that is not re-measured stops being true,
    # and the only way to notice is to fail a build over it. The floor is set
    # generously under the measured number: this is a check against a
    # regression of kind -- a per-byte copy coming back, a cache that stopped
    # hitting -- not a benchmark of the machine it happens to run on.
    heading "Gate"
    if gRate < int64(floor1):
      err $gRate & " requests/second is under the floor of " & $floor1
      return 1
    ok $gRate & " requests/second, floor " & $floor1
  result = 0

quit(main())
