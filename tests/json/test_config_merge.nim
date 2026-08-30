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

# --- nested document, ABSENT LEAF under an existing object: CREATED ---------
#
# This is the bug the whole change fixes. The client host used to REFUSE this,
# so 23 of sain's own settings (roles.*, botLoot.*) silently failed to persist.
# The member must land INSIDE the existing "global" object -- NOT as a flat
# top-level "global.missing" the mod would never read (the backend's failure).
# The finished-state assertion is a byte check AND a re-read: pathGet must find
# exactly what was written, which is what "re-read at boot" reduces to.
block:
  let doc = "{\n  \"global\": {\n    \"brainOn\": false\n  }\n}\n"
  var err = ""
  var merged = ""
  checkRc("absent leaf under an existing object is CREATED",
          configMerge(doc, "global.missing", "true", err, merged), mgOk)
  check("new leaf inserted inside the existing object, sibling kept", merged,
        "{\n  \"global\": {\n    \"brainOn\": false,\n    \"missing\": true\n  }\n}\n")
  var back = ""
  if not pathGet(merged, "global.missing", back) or back != "true":
    inc failures
    echo "FAIL  the created key does not read back: got \"", back, "\""
  else:
    echo "ok    the created key reads back at the dotted path"
  # The negative that a flat-insert bug would trip: there must be NO top-level
  # member literally named "global.missing".
  if merged.contains("\"global.missing\""):
    inc failures
    echo "FAIL  a flat \"global.missing\" member was created -- the old backend bug"
  else:
    echo "ok    no flat dotted member was created"

# --- nested document, ABSENT INTERMEDIATE segment: whole chain CREATED ------
#
# "roles" exists, "roles.pmc" does not. The created scaffold is compact JSON;
# the pre-existing bytes keep their own formatting. Correctness is the re-read.
block:
  let doc = "{\n  \"roles\": {\n    \"scav\": {\n      \"difficulty\": \"normal\"\n    }\n  }\n}\n"
  var err = ""
  var merged = ""
  checkRc("absent intermediate segment: chain created",
          configMerge(doc, "roles.pmc.difficulty", "\"hard\"", err, merged), mgOk)
  var back = ""
  if not pathGet(merged, "roles.pmc.difficulty", back) or back != "hard":
    inc failures
    echo "FAIL  created nested chain does not read back: got \"", back, "\""
  else:
    echo "ok    created nested chain reads back"
  var kept = ""
  if not pathGet(merged, "roles.scav.difficulty", kept) or kept != "normal":
    inc failures
    echo "FAIL  the pre-existing sibling was disturbed: got \"", kept, "\""
  else:
    echo "ok    the pre-existing sibling survived untouched"

# --- absent path whose prefix is a SCALAR: still REFUSED -------------------
#
# "a" is a number; "a.b" cannot be created without overwriting it. Refusing is
# the only safe answer, and the refusal must name the offending segment.
block:
  let doc = "{\n  \"a\": 1\n}\n"
  var err = ""
  var merged = ""
  checkRc("dotted path through a scalar is REFUSED",
          configMerge(doc, "a.b", "2", err, merged), mgNotFound)
  check("a refused merge produces NO document", merged, "")
  if err.len == 0 or not err.contains("a"):
    inc failures
    echo "FAIL  the refusal must name the path; err was: ", err
  else:
    echo "ok    the scalar-conflict refusal names the segment"

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
