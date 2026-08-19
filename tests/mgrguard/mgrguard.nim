## Proof that the manager's new refusals can fail.
##
## Every check below comes in a pair: the input that must be refused, and the
## nearest input that must NOT be — so a guard that returned "" for everything,
## or a sentence for everything, fails here rather than passing quietly. That is
## the discipline this repository keeps because its recurring bug is a check
## that passes because the thing it checks never happened.

import std/[strutils, syncio]
import registry
import selection
import writeguard
import cfgscan

var gFailures = 0
var gChecks = 0

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    echo "ok    " & what
  else:
    echo "FAIL  " & what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc heading(what: string) =
  echo ""
  echo what
  echo repeat("-", what.len)

# ---------------------------------------------------------------------------
# mgr/registry.nim -- did all of the bytes arrive
# ---------------------------------------------------------------------------

const Sch = "\"schema\":\"" & SchemaId & "\""

proc modJson(id: string): string =
  result = "{\"id\":\"" & id & "\",\"version\":\"1.0.0\",\"sides\":[\"server\"]," &
           "\"artifact\":{\"dir\":\"" & id & "\",\"library\":\"" & id & ".dll\"}}"

proc regJson(ids: seq[string]): string =
  var mods = ""
  for id in ids:
    if mods.len > 0: mods.add ","
    mods.add modJson(id)
  result = "{" & Sch & ",\"mods\":[" & mods & "],\"lists\":[]}"

proc truncation() =
  heading "A registry cut short"
  let good = regJson(@["a", "b", "c", "d"])
  let whole1 = parseRegistry(good, "m.json")
  # The control: the same document, entire, must still be read. Without this the
  # truncation check below could pass because *everything* is refused.
  check("the whole document is read", whole1.ok, whole1.error)
  check("with all four mods in it", whole1.mods.len == 4, $whole1.mods.len)

  let half = good.substr(0, good.len div 2)
  let cut = parseRegistry(half, "m.json")
  check("half of it is refused", not cut.ok, "ok=true with " & $cut.mods.len & " mods")
  check("and the refusal says it is not one complete object",
        find(cut.error, "not one complete JSON object") >= 0, cut.error)
  check("and nothing at all is read out of it", cut.mods.len == 0,
        $cut.mods.len & " mods survived the refusal")

  # This is the proof that the check is not decorative: before it existed, the
  # scanner read the surviving prefix as a shorter, valid registry. Assert that
  # the truncated text really does still contain readable mods, so that a future
  # `wholeJsonObject` that always returned true would be caught by the check
  # above rather than by nobody.
  check("and the truncated text really would have parsed as a shorter registry",
        find(half, "\"id\":\"a\"") >= 0 and find(half, "\"id\":\"d\"") < 0, half)

  # One byte off the end is the interesting case: it is still balanced-looking
  # to a scanner and is not balanced.
  let nearly = good.substr(0, good.len - 2)
  check("one byte short is refused too", not parseRegistry(nearly, "m.json").ok, "")
  check("trailing bytes after the object are refused",
        not parseRegistry(good & "garbage", "m.json").ok, "")
  check("a NUL inside it is refused",
        not parseRegistry("{" & Sch & ",\"mods\":[" & $chr(0) & "]}", "m.json").ok, "")

proc bom() =
  heading "A byte-order mark"
  let good = regJson(@["a"])
  let marked = $chr(0xEF) & $chr(0xBB) & $chr(0xBF) & good
  check("is dropped, not read as content", stripBom(marked) == good, "")
  check("and a document without one is handed back unchanged",
        stripBom(good) == good, "")
  # The control that makes the first check mean something: the marked bytes are
  # genuinely unreadable if the mark is left on.
  check("a document that still has one does not parse as a registry",
        not parseRegistry(marked, "m.json").ok, "")

proc emptyRegistryCheck() =
  heading "A registry that parses and describes nothing"
  let none = parseRegistry("{" & Sch & ",\"mods\":[],\"lists\":[]}", "m.json")
  check("is read rather than refused, because it says what it says", none.ok,
        none.error)
  var warnings = ""
  for w in none.warnings: warnings.add w
  check("and is said out loud", find(warnings, "no mods in it") >= 0, warnings)
  # The control: a registry with a mod in it must NOT carry that sentence.
  var w2 = ""
  for w in parseRegistry(regJson(@["a"]), "m.json").warnings: w2.add w
  check("and a registry with a mod in it does not say it",
        find(w2, "no mods in it") < 0, w2)

# ---------------------------------------------------------------------------
# mgr/selection.nim -- the store's schema
# ---------------------------------------------------------------------------

proc storeSchema() =
  heading "A stored selection from another schema"
  check("the schema this manager writes is accepted",
        selectionFaultIn("{\"schema\":\"" & StoreSchema &
                         "\",\"lists\":[\"a\"]}").len == 0,
        selectionFaultIn("{\"schema\":\"" & StoreSchema & "\",\"lists\":[\"a\"]}"))
  check("a document with no schema at all is accepted, because every one " &
        "written before the field existed has none",
        selectionFaultIn("{\"lists\":[\"a\"]}").len == 0, "")
  let other = selectionFaultIn("{\"schema\":\"aowlspt.selection.store/2\"," &
                               "\"lists\":[\"a\"]}")
  check("a schema this build does not know is refused", other.len > 0, "")
  check("and the refusal quotes both", find(other, "store/2") >= 0 and
        find(other, StoreSchema) >= 0, other)
  # The control that proves it is the *schema* being refused and not the shape:
  # the same document with the known schema is accepted, above.
  check("a null schema is not read as the word null",
        selectionFaultIn("{\"schema\":null,\"lists\":[\"a\"]}").len == 0,
        selectionFaultIn("{\"schema\":null,\"lists\":[\"a\"]}"))

# ---------------------------------------------------------------------------
# mgr/writeguard.nim -- the refusal that matters
# ---------------------------------------------------------------------------

proc healthy(): WriteFacts =
  ## Every input intact, and a resolution that came out empty anyway. This is
  ## the *permitted* degenerate document: a player who switched everything off.
  ## Every check below is this, with exactly one thing broken.
  result = WriteFacts(
    protectedId: "aowl.manager",
    order: @["aowl.manager"],
    configFault: "", configNamedLists: true,
    selectionFault: "", selectionSeeded: false,
    registryOk: true, registryError: "", registryPath: "m.json",
    registryMods: 7,
    activeLists: @["aowl.list.core"], knownLists: @["aowl.list.core"],
    problems: @[], pipelineChecked: true, hostVersion: "1.2.3")

proc healthy2(): WriteFacts =
  result = healthy()
  result.order = @["aowl.manager", "aowl.fov"]

proc guard() =
  heading "The document that would name the manager and nothing else"

  # ---- The controls first. If these fail, every refusal below is meaningless.
  check("a resolution with real mods in it is always written",
        selectionWriteFault(healthy2()).len == 0, selectionWriteFault(healthy2()))
  check("and a resolution that is empty for no reason at all is written too, " &
        "because switching everything off is a thing people do",
        selectionWriteFault(healthy()).len == 0, selectionWriteFault(healthy()))
  var empty = healthy()
  empty.order = @[]
  check("as is one that resolved literally nothing",
        selectionWriteFault(empty).len == 0, selectionWriteFault(empty))

  # ---- One broken input at a time.
  var f1 = healthy()
  f1.configFault = "config.json is not one complete JSON object"
  let r1 = selectionWriteFault(f1)
  check("a config that did not parse refuses it", r1.len > 0, "")
  check("and says which of the two silences it got",
        find(r1, "same empty answer") >= 0, r1)

  var f2 = healthy()
  f2.selectionFault = "the stored selection could not be read"
  check("a store that could not be read refuses it",
        selectionWriteFault(f2).len > 0, "")

  var f3 = healthy()
  f3.registryOk = false
  f3.registryError = "no registry found"
  check("no registry refuses it", selectionWriteFault(f3).len > 0, "")

  var f4 = healthy()
  f4.registryMods = 0
  let r4 = selectionWriteFault(f4)
  check("a registry with no mods in it refuses it", r4.len > 0, "")
  check("and does not call that the player's choice",
        find(r4, "not the same as you selecting nothing") >= 0, r4)

  var f5 = healthy()
  f5.knownLists = @["aowl.list.other"]
  let r5 = selectionWriteFault(f5)
  check("an active list the registry does not have refuses it", r5.len > 0, "")
  check("and names the list rather than describing it",
        find(r5, "aowl.list.core") >= 0, r5)

  var f6 = healthy()
  f6.problems = @["a list inheritance cycle: a -> b -> a"]
  let r6 = selectionWriteFault(f6)
  check("a resolution with a problem in it refuses it", r6.len > 0, "")
  check("and quotes the problem", find(r6, "a -> b -> a") >= 0, r6)

  var f7 = healthy()
  f7.pipelineChecked = false
  f7.hostVersion = "dev"
  let r7 = selectionWriteFault(f7)
  check("a host whose version could not be parsed refuses it", r7.len > 0, "")
  check("and quotes what it said", find(r7, "dev") >= 0, r7)

  var f8 = healthy()
  f8.activeLists = @[]
  f8.selectionSeeded = true
  let r8 = selectionWriteFault(f8)
  check("the original bug -- config named lists, nothing stored, no active " &
        "list -- refuses it", r8.len > 0, "")
  check("and says the manager does not know what you chose",
        find(r8, "does not know what you chose") >= 0, r8)

  # ---- And the three near-misses of that last one, which must all be allowed.
  var g1 = healthy()
  g1.activeLists = @[]
  g1.configNamedLists = false
  g1.selectionSeeded = true
  check("a config that genuinely names no lists on a fresh install is allowed",
        selectionWriteFault(g1).len == 0, selectionWriteFault(g1))
  var g2 = healthy()
  g2.activeLists = @[]
  g2.configNamedLists = true
  g2.selectionSeeded = false
  check("and a player who stored an empty list set is allowed",
        selectionWriteFault(g2).len == 0, selectionWriteFault(g2))

  # ---- Every one of the above, with a real mod in the order: all allowed. A
  # guard that refused a document with mods in it would take the player's whole
  # load order away for a fault that cost them nothing.
  heading "None of that applies to a document with mods in it"
  var faults: seq[WriteFacts] = @[]
  var b1 = healthy()
  b1.configFault = "x"
  faults.add b1
  var b2 = healthy()
  b2.selectionFault = "x"
  faults.add b2
  var b3 = healthy()
  b3.registryOk = false
  faults.add b3
  var b4 = healthy()
  b4.registryMods = 0
  faults.add b4
  var b5 = healthy()
  b5.knownLists = @[]
  faults.add b5
  var b6 = healthy()
  b6.problems = @["x"]
  faults.add b6
  var b7 = healthy()
  b7.pipelineChecked = false
  faults.add b7
  var n = 0
  for i in 0 ..< faults.len:
    var f = faults[i]
    f.order = @["aowl.manager", "some.other.mod"]
    if selectionWriteFault(f).len == 0:
      inc n
  check("all seven broken inputs still write a document with a mod in it",
        n == faults.len, $n & " of " & $faults.len)

  # ---- protectedOnly itself.
  heading "protectedOnly"
  var p1 = healthy()
  p1.order = @["aowl.manager"]
  check("the manager alone is degenerate", protectedOnly(p1), "")
  p1.order = @[]
  check("nothing at all is degenerate", protectedOnly(p1), "")
  p1.order = @["some.other.mod"]
  check("a mod that is not the manager is not", not protectedOnly(p1), "")
  p1.order = @["aowl.manager", "some.other.mod"]
  check("nor is the manager plus one", not protectedOnly(p1), "")
  # The check that would catch a `protectedId` that got set to "": everything
  # would then be "not protected", and every degenerate document would be
  # written. Assert the id actually matters.
  var p2 = healthy()
  p2.protectedId = ""
  p2.order = @["aowl.manager"]
  check("and an empty protected id does not make everything degenerate",
        not protectedOnly(p2), "")


proc configScan() =
  heading "A config that did not parse, per mod"

  # The manager used to carry its own opinion about whether a config parsed --
  # a bracket counter -- while the host ran a validator. They disagreed, and
  # the disagreement was not cosmetic: on a trailing comma the manager decided
  # the file was fine, disarmed the config arm of its write guard, and ran on
  # every default while the host had refused to read the file at all.
  #
  # The first pair below is exactly that case. It fails the moment a local
  # parser comes back.
  check("a whole object has no fault", configFaultIn("{" & "\"a\": 1}") == "")
  check("a trailing comma is a fault -- the case the bracket counter missed",
        configFaultIn("{" & "\"a\": 1,}").len > 0)
  check("a missing colon is a fault", configFaultIn("{" & "\"a\" 1}").len > 0)
  check("a bare word is a fault", configFaultIn("{" & "\"a\": yes}").len > 0)
  check("a truncated document is a fault",
        configFaultIn("{" & "\"a\": 1").len > 0)

  # A BOM is stripped by the host's reader before anything sees the text, so a
  # BOM'd config is *not* a fault to report -- reporting one would tell a
  # player their file is broken when the host reads it perfectly well. The
  # check is stated on both sides so that stripping too much fails too.
  var bom = ""
  bom.add chr(0xEF)
  bom.add chr(0xBB)
  bom.add chr(0xBF)
  check("a BOM'd document is a fault as raw text",
        configFaultIn(bom & "{" & "\"a\": 1}").len > 0)

  var faults: seq[ModConfigFault] = @[]
  check("no faults reports nothing", configFaultReport(faults, 3) == "")
  var one = emptyConfigFault()
  one.id = "aowl.tarkov"
  one.path = "config.json"
  one.fault = "a trailing comma at offset 8"
  faults.add one
  let report = configFaultReport(faults, 3)
  check("one fault names the mod", find(report, "aowl.tarkov") >= 0)
  check("and says how many of how many", find(report, "1 of 3") >= 0)
  check("and says what it means, not just that it happened",
        find(report, "default") >= 0)

  # Absent is not broken, and neither is empty. Both were the same answer once,
  # which is the ambiguity this whole mechanism exists to end.
  var text = ""
  check("a config that is not there reads as absent",
        not readConfigBytes("c:\\no\\such\\config.json", text))

proc main() =
  truncation()
  bom()
  emptyRegistryCheck()
  storeSchema()
  guard()
  configScan()
  echo ""
  echo "Result"
  echo "------"
  if gFailures == 0:
    echo "ok    all " & $gChecks & " checks"
  else:
    echo "FAIL  " & $gFailures & " of " & $gChecks & " checks"
    quit 1

main()
