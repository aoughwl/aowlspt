## What a config edit does to the DOCUMENT.
##
## The client host could not write config at all until now, so this is the
## first check that the merge rules behave -- and it asserts the FINISHED
## bytes, never the status. A status-only check here could not tell a write
## that landed in the right member from one that appended a flat
## `"global.brainOn"` next to it, which is the exact failure this refuses.
##
## Run: aowl run tests/json/test_config_merge.nim

import std/[strutils, syncio]
import ../../host/common/jsonpath

var failures = 0

proc check(what: string; got, want: string) =
  if got == want:
    echo "ok    ", what
  else:
    inc failures
    echo "FAIL  ", what
    echo "      want: ", want.replace("\r", "\\r").replace("\n", "\\n")
    echo "      got:  ", got.replace("\r", "\\r").replace("\n", "\\n")

proc checkRc(what: string; got, want: MergeResult) =
  if got == want:
    echo "ok    ", what
  else:
    inc failures
    echo "FAIL  ", what, ": want ", $want, " got ", $got

# --- flat document, existing key: replaced in place, nothing else moves ----
block:
  let doc = "{\n  \"enabled\": true,\n  \"quality\": \"2k\"\n}\n"
  var err = ""
  var merged = ""
  checkRc("flat existing key returns mgOk",
          configMerge(doc, "quality", "\"4k\"", err, merged), mgOk)
  check("flat existing key replaced in place", merged,
        "{\n  \"enabled\": true,\n  \"quality\": \"4k\"\n}\n")

# --- nested document, existing dotted path ---------------------------------
block:
  let doc = "{\n  \"global\": {\n    \"brainOn\": false\n  },\n  \"server\": {\n    \"port\": 1\n  }\n}\n"
  var err = ""
  var merged = ""
  checkRc("nested existing path returns mgOk",
          configMerge(doc, "global.brainOn", "true", err, merged), mgOk)
  check("nested existing path edited in place, siblings untouched", merged,
        "{\n  \"global\": {\n    \"brainOn\": true\n  },\n  \"server\": {\n    \"port\": 1\n  }\n}\n")

# --- nested document, ABSENT dotted path: REFUSED, document unchanged ------
#
# The whole reason this module exists rather than the backend's merge: that
# one would have produced a top-level "global.missing" member here.
block:
  let doc = "{\n  \"global\": {\n    \"brainOn\": false\n  }\n}\n"
  var err = ""
  var merged = ""
  checkRc("absent dotted path is REFUSED",
          configMerge(doc, "global.missing", "true", err, merged), mgNotFound)
  check("a refused merge produces NO document", merged, "")
  if err.len == 0 or not err.contains("global.missing"):
    inc failures
    echo "FAIL  the refusal must name the path; err was: ", err
  else:
    echo "ok    the refusal names the path"

# --- flat document, absent top-level key: inserted, CRLF preserved ---------
block:
  let doc = "{\r\n  \"enabled\": true\r\n}\r\n"
  var err = ""
  var merged = ""
  checkRc("absent top-level key inserted",
          configMerge(doc, "quality", "\"4k\"", err, merged), mgOk)
  check("insert keeps the file's CRLF endings", merged,
        "{\r\n  \"enabled\": true,\r\n  \"quality\": \"4k\"\r\n}\r\n")

# --- empty object ----------------------------------------------------------
block:
  let doc = "{}\n"
  var err = ""
  var merged = ""
  discard configMerge(doc, "quality", "\"4k\"", err, merged)
  check("insert into an empty object", merged, "{\n  \"quality\": \"4k\"\n}\n")

# --- empty value is refused ------------------------------------------------
block:
  var err = ""
  var merged = ""
  checkRc("empty value refused",
          configMerge("{\"a\":1}", "a", "", err, merged), mgBadArg)
  checkRc("empty key refused",
          configMerge("{\"a\":1}", "", "1", err, merged), mgBadArg)

if failures == 0:
  echo "PASS  config merge"
else:
  echo "FAIL  config merge: ", failures, " check(s) failed"
  quit(1)
