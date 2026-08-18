## Asserts that the nimony view of the ABI matches the C header.
##
## This test exists because getting it wrong does not crash — it corrupts. A
## struct whose fields sit at different offsets on the two sides of the boundary
## reads a length as a pointer and a pointer as a length, and the failure shows
## up somewhere else entirely, usually under load.
##
## The numbers below are the x86-64 System V / Win64 layout of the structs in
## `abi/aowlspt_abi.h`, worked out by hand. `tests/abi_layout.c` computes the
## same numbers with the real C compiler over the real header, and
## `tools/aowlspt-test.ps1` runs both and diffs them — so this file is checked
## against the header, not merely against itself.
##
## Run: nimony c tests/abi_layout.nim && ./nimcache/*/abi_layout.exe

import std/syncio
import ".." / aowl / src / aowlspt / abi

var failures = 0

proc check(what: string; got, want: int) =
  if got == want:
    echo "  ok    ", what, " = ", got
  else:
    echo "  FAIL  ", what, " = ", got, ", expected ", want
    inc failures

proc main =
  echo "aowlspt ABI layout (x86-64)"

  # 8-byte pointer + 4-byte length + 4 bytes tail padding.
  check "sizeof(AowlSlice)", sizeof(AowlSlice), 16
  check "sizeof(AowlBuffer)", sizeof(AowlBuffer), 16

  # int32 size + 3 x uint32/int32 (16 bytes of header, already 8-aligned)
  # + 4 slices (64) + uint32 encodings + 4 pad + 2 slices (32).
  check "sizeof(HostInfo)", sizeof(HostInfo), 120

  # int32 size + 4 pad + ctx + info + 18 function pointers = 24 + 18*8.
  check "sizeof(HostApi)", sizeof(HostApi), 168

  # int32 size + 2 uint32 (12) + 4 pad + 5 slices (80) + 2 uint32 (8).
  check "sizeof(ModInfo)", sizeof(ModInfo), 104

  # int32 size + 4 pad + self + 5 function pointers.
  check "sizeof(ModApi)", sizeof(ModApi), 56

  # The enum values are wire values; renumbering one silently rewires the ABI.
  check "ord(sideServer)", ord(sideServer), 1
  check "ord(sideClient)", ord(sideClient), 2
  check "ord(sideSim)", ord(sideSim), 3
  check "ord(llError)", ord(llError), 5
  check "ord(rkDynamic)", ord(rkDynamic), 1
  check "ord(pkFinalizer)", ord(pkFinalizer), 2

  # `sides` is a bitmask of 1 << side, not an ordinal.
  check "sideBit(sideServer)", int(sideBit(sideServer)), 2
  check "sideBit(sideClient)", int(sideBit(sideClient)), 4
  check "sideBit(sideSim)", int(sideBit(sideSim)), 8

  check "flagBits({mfHotReloadable})", int(flagBits({mfHotReloadable})), 1
  check "flagBits({mfThreadSafe})", int(flagBits({mfThreadSafe})), 2
  check "flagBits(both)", int(flagBits({mfHotReloadable, mfThreadSafe})), 3

  check "AbiVersion", int(AbiVersion), 1

  if failures == 0:
    echo "all layout checks passed"
  else:
    echo failures, " layout check(s) FAILED"
    quit 1

main()
