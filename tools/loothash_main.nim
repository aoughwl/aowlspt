## `aowl loothash` -- generate N raids of loot at a fixed seed and print one
## digest of every byte produced.
##
## The instrument that was missing. "Defaults reproduce the previous
## behaviour" had been argued from control flow -- each new knob is skipped at
## its default, therefore the RNG stream is unchanged -- and an argument about
## control flow is not a measurement of output. This generates the output and
## hashes it, so the claim is checkable by someone who does not believe it.
##
## Use it BOTH ways. Identical digests across a change prove nothing on their
## own: an instrument that returns a constant would also produce them. Flip one
## knob, watch the digest move, and only then does the first half mean
## anything.
##
##   aowl loothash --seed s1 --count 8
##   aowl loothash --seed s1 --count 8 --rules "base:5448fe124bdc2da5018b4567 *0.25"
##   aowl loothash --seed s1 --count 8 --explain <tplId>
##
## `--doc <file>` runs it over a JSON document instead of the built-in fixture,
## so the same digest can be taken over a real imported database.

import std/syncio
import std/os
import std/strutils
import aowlspt
import emu/loot
import emu/lootconfig

{.emit: """#include <stdint.h>""".}
{.emit: """#include <stdlib.h>""".}
{.emit: """#include <string.h>""".}
{.emit: """#include "aowlspt_abi.h" """.}
{.emit: """#include "aowlspt_shim.h" """.}

{.emit: """
#include <stdio.h>
void aowlspt_nim_log(void* c, int32_t lv, void* m, int32_t n) { (void)c; (void)lv; fprintf(stderr, "    host: %.*s\n", (int)n, (const char*)m); }
void aowlspt_nim_last_error(void* c, void* p, void* n) { (void)c; *(void**)p = 0; *(int32_t*)n = 0; }
int32_t aowlspt_nim_config_get(void* c, void* k, int32_t kl, void* p, void* n) { return -1; }
int32_t aowlspt_nim_config_set(void* c, void* k, int32_t kl, void* v, int32_t vl) { return -1; }
int32_t aowlspt_nim_call(void* c, void* t, int32_t tl, void* a, int32_t al, void* p, void* n) { return -1; }
int32_t aowlspt_nim_resolve(void* c, void* t, int32_t tl, void* h) { return -1; }
void aowlspt_nim_handle_release(void* c, uint64_t h) { (void)c; (void)h; }
int32_t aowlspt_nim_event_emit(void* c, void* nm, int32_t nl, void* p, int32_t pl) { return -1; }
int64_t aowlspt_nim_now_ms(void* c) { (void)c; return 0; }
int32_t aowlspt_nim_invoke_main(void* c, void* cb, void* u) { return -1; }
int32_t aowlspt_nim_schedule(void* c, int32_t d, void* cb, void* u) { return -1; }
int32_t aowlspt_nim_event_subscribe(void* c, void* nm, int32_t nl, void* h, void* u) { return -1; }
int32_t aowlspt_nim_patch(void* c, void* t, int32_t tl, int32_t k, void* h, void* u) { return -1; }
int32_t aowlspt_nim_db_get(void* c, void* p, int32_t pl, void* op, void* on) { return -1; }
int32_t aowlspt_nim_db_patch(void* c, void* p, int32_t pl, void* v, int32_t vl) { return -1; }
int32_t aowlspt_nim_route_register(void* c, void* u, int32_t ul, int32_t k, void* h, void* us) { return -1; }
int32_t aowlspt_nim_store_get(void* c, void* k, int32_t kl, void* op, void* on) { return -1; }
int32_t aowlspt_nim_store_set(void* c, void* k, int32_t kl, void* v, int32_t vl) { return -1; }
int32_t aowlspt_nim_store_list(void* c, void* p, int32_t pl, void* op, void* on) { return -1; }
""".}

proc cHostNew(ctx: pointer; side: int32; hostName, hostVersion,
              sptVersion, gameVersion, modDir, dataDir: cstring): pointer
  {.importc: "aowl_hostapi_new", nodecl.}

proc readDoc(path: string): string =
  ## Unreadable comes back EMPTY and the caller refuses; it never comes back as
  ## a document the generator would then hash as though it were real.
  result = ""
  var f: File
  if not open(f, path, fmRead):
    return
  try:
    result = readAll(f)
  except:
    result = ""
  close(f)

var api: ModApi

proc main() =
  let hostPtr = cHostNew(cast[pointer](0), 3, "aowl loothash", "0", "0", "0",
                         "", "")
  if bindHost(cast[ptr HostApi](hostPtr), addr api) != Ok:
    echo "FAIL could not bind the stub host"
    quit(2)

  var seed = "loothash"
  var location = "testmap"
  var count = 8
  var rules = ""
  var explainTpl = ""
  var doc = ""
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    case a
    of "--seed":
      inc i; seed = (if i <= n: paramStr(i) else: seed)
    of "--map", "--location":
      inc i; location = (if i <= n: paramStr(i) else: location)
    of "--count":
      inc i
      if i <= n:
        try:
          count = parseInt(paramStr(i))
        except:
          discard
    of "--rules":
      inc i; rules = (if i <= n: paramStr(i) else: "")
    of "--explain":
      inc i; explainTpl = (if i <= n: paramStr(i) else: "")
    of "--doc":
      inc i; doc = (if i <= n: paramStr(i) else: "")
    else:
      echo "loothash: unknown argument " & a
      quit(2)
    inc i
  if count < 1: count = 1

  var document = Fixture
  var source = "the built-in fixture"
  if doc.len > 0:
    document = readDoc(doc)
    source = doc
    if document.len == 0:
      echo "FAIL --doc " & doc & " is empty or unreadable. INCONCLUSIVE."
      quit(2)

  # The rule set is reported before anything is generated, so a typo shows up
  # as "0 rules" here rather than as an unexplained identical digest later.
  var rs = newRuleSet()
  addRuleText(rs, rules)
  echo "loothash: source   " & source
  echo "loothash: map      " & location
  echo "loothash: seed     " & seed & "  count " & $count
  echo "loothash: " & summary(rs)
  if rules.len > 0 and rs.len == 0:
    echo "FAIL --rules was given but NOT ONE clause parsed. A run with a " &
         "silently empty rule set would produce the defaults digest and read " &
         "as 'the knob changed nothing'. Refusing."
    quit(2)

  var items = 0
  var bytes = 0
  let digest = lootBatchHashText(document, location, seed, rules, count,
                                 items, bytes)
  echo "loothash: items    " & $items
  echo "loothash: bytes    " & $bytes
  echo "loothash: DIGEST   " & digest

  if explainTpl.len > 0:
    var cfg = defaultLootConfig()
    addRuleText(cfg.rules, rules)
    cfg.explainTpl = explainTpl
    var it2 = 0
    var by2 = 0
    discard lootBatchHash(textDb(document), cfg, location, seed, 1, it2, by2)
    echo "loothash: (the explain trace is emitted through the host log above)"

  if items == 0:
    echo "loothash: NOTE zero items were generated. The digest is stable but " &
         "it is a digest of nothing -- that is INCONCLUSIVE, not a pass."

main()
