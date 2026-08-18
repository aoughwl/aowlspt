## The per-mod key/value store behind `store_get` / `store_set` / `store_list`.
##
## Shared by both hosts, because a mod that keeps state must keep it the same
## way on either side of the pipeline. One file per key under
##
##     <root>/store/<mod-guid>/<key>
##
## A mod could open files itself. Then every mod invents its own layout inside
## the install, and neither the host nor the player can move, back up or clear
## one mod's data without knowing that mod. Routing it through the ABI costs a
## function call and buys a single answer to "where does this mod's data live".
##
## Keys are flat and restricted to `[A-Za-z0-9._-]`. A key outside that set is
## **refused, not sanitised**: mapping `a/b` and `a.b` onto one file would be a
## data-loss bug that only shows up with two keys that look nothing alike. The
## same rule stops `..\..\` from ever being a key.

import std/strutils
import aowlsptinstall/winfs

var gStoreRoot = ""

proc storeInit*(root: string) =
  ## `root` is the host's own directory -- the store goes in `store/` beneath it.
  gStoreRoot = joinPath(root, "store")

proc storeRoot*(): string = gStoreRoot

proc validKey*(key: string): bool =
  ## Flat, and nothing that can escape the directory. Also bounded: a key long
  ## enough to overflow MAX_PATH would fail at the filesystem with an error
  ## nobody can act on.
  if key.len == 0 or key.len > 180:
    return false
  for ch in key:
    let isLower = ch >= 'a' and ch <= 'z'
    let isUpper = ch >= 'A' and ch <= 'Z'
    let isDigit = ch >= '0' and ch <= '9'
    if not (isLower or isUpper or isDigit or ch == '.' or ch == '_' or
            ch == '-'):
      return false
  # A leading dot would make the file hidden on some tools' view of the
  # directory, and `.` / `..` are not keys.
  if key[0] == '.':
    return false
  result = true

proc guidDir(guid: string): string =
  ## The guid is a mod's own identifier and reaches here from its `describe`, so
  ## it is checked exactly as a key is -- a mod cannot pick a guid that puts its
  ## store somewhere else.
  var safe = ""
  for ch in guid:
    let isLower = ch >= 'a' and ch <= 'z'
    let isUpper = ch >= 'A' and ch <= 'Z'
    let isDigit = ch >= '0' and ch <= '9'
    if isLower or isUpper or isDigit or ch == '.' or ch == '_' or ch == '-':
      safe.add ch
    else:
      safe.add '_'
  if safe.len == 0 or safe[0] == '.':
    safe = "unnamed"
  result = joinPath(gStoreRoot, safe)

proc storeRead*(guid, key: string; into: var string; error: var string): bool =
  into = ""
  error = ""
  if gStoreRoot.len == 0:
    error = "the store is not initialised"
    return false
  if not validKey(key):
    error = "not a valid store key: " & key
    return false
  let path = joinPath(guidDir(guid), key)
  if not exists(path):
    error = "no stored value for " & key
    return false
  if not readTextFile(path, into):
    error = "could not read " & path
    return false
  result = true

proc storeWrite*(guid, key, value: string; error: var string): bool =
  error = ""
  if gStoreRoot.len == 0:
    error = "the store is not initialised"
    return false
  if not validKey(key):
    error = "not a valid store key: " & key
    return false
  let dir = guidDir(guid)
  let mk = ensureDir(dir)
  if not mk.ok:
    error = "could not create " & dir & " (error " & $int(mk.err) & ")"
    return false
  let w = writeTextFile(joinPath(dir, key), value)
  if not w.ok:
    error = "could not write " & key & " (error " & $int(w.err) & ")"
    return false
  result = true

proc storeKeys*(guid, prefix: string): string =
  ## A JSON array of the keys under `prefix`. An empty store is `[]`, not an
  ## error: "no profiles yet" is a normal state for a mod to be started in.
  var out1 = "["
  let dir = guidDir(guid)
  if isDirectory(dir):
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(dir, files, dirs)
    var first = true
    for f in files:
      let name = baseName(f)
      if prefix.len > 0:
        if name.len < prefix.len or name.substr(0, prefix.len - 1) != prefix:
          continue
      if not first: out1.add ","
      first = false
      out1.add "\"" & name & "\""
  out1.add "]"
  result = out1
