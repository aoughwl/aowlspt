## THE THREE GATES A MOD'S PATCH-BY-RVA MUST PASS BEFORE A BYTE IS WRITTEN.
##
## `installPatch` already turns an `@0xRVA/<shape>[!<hex>]` spec into a code
## pointer through `resolveByRva`, which answers four questions -- is
## GameAssembly.dll mapped, is the address committed executable memory, is it
## inside the `il2cpp` PE section, and (IF the caller declared any) do the
## bytes match the startup snapshot. That is everything about the ADDRESS.
##
## It is not everything about the WRITE. Three things could still be true of a
## perfectly readable, perfectly verified address, and each of them turns a
## detour into a silent failure rather than an absent one:
##
##   1. **Nothing was byte-compared.** `resolveByRva` warns and continues when
##      the spec carries no `!<hex>` suffix -- correct for the host's own
##      binder, which has other evidence, and wrong for a mod, which has none.
##      A green light from a comparison that compared nothing is exactly the
##      check-that-cannot-fail this repo keeps paying for.
##   2. **The address is SHARED.** 28.3% of by-name lookups on this build land
##      on an RVA with more than one owner (6,261 of them). *Calling* a folded
##      body is fine -- it is correct code for the receiver passed. *Detouring*
##      one fires for every method folded onto it, which is a write with
##      unbounded blast radius. The offline name index carries the per-entry
##      share count, so this is answerable, and `unknown` is a refusal rather
##      than "probably one".
##   3. **Something already owns the function.** The second detour on a
##      function overwrites the first's trampoline and kills the first feature
##      with no error anywhere. The right move is to ride the existing detour
##      as a drain; the wrong move is to install and find out in a raid.
##
## All three are decided here, all three refuse OUT LOUD with the check that
## declined, and none of them is a warning that a caller can miss.
##
## ### Why gate 3 is answered from live memory when everything else must not be
##
## The standing rule is that a prologue is verified against the STARTUP
## SNAPSHOT, never live memory, because verifying after another feature patched
## the same function reads that feature's trampoline and self-rejects a correct
## RVA. Gate 3 asks the opposite question on purpose -- "have the live bytes
## moved away from the snapshot" -- and a difference is precisely the evidence
## it wants.
##
## The trap in doing that is a snapshot captured too late: if the function was
## already detoured before its first `aowl_pro_capture`, the "original" bytes
## ARE the trampoline, live matches snapshot, and the check passes vacuously.
## It cannot happen on this path, and the reason is an ordering rather than an
## assumption: gate 1 makes a declared prologue mandatory, and `resolveByRva`
## has already compared it against that same snapshot row before this file runs.
## So either the snapshot holds the true original -- and a live difference means
## somebody else patched it -- or it holds a trampoline, in which case the
## declared bytes did NOT match and the patch was already refused upstream. The
## two checks are only sound together, which is why gate 1 is not optional.
##
## Three outcomes, never two: the comparison itself answers same / differs /
## **cannot tell** (no snapshot row, module gone, page unreadable), and cannot
## tell REFUSES. "I could not look" is not a pass.

{.emit: """
/* Live bytes at GameAssembly+rva against the STARTUP SNAPSHOT row captured by
 * `aowlspt_prologue.h`. Three-state on purpose:
 *      1  -- they differ: something has written to this function's prologue
 *      0  -- identical: nothing has
 *     -1  -- CANNOT TELL: no snapshot row, module not mapped, page not
 *            committed-executable, or fewer than `n` bytes in one region.
 *
 * -1 is never folded into 0. A caller that treated "I could not read it" as
 * "it is untouched" would install the second detour on a function in exactly
 * the conditions where reading failed. Bounded, guarded on every hop, and it
 * writes nothing.
 */
static int32_t aowl_prva_live_differs(uint32_t rva, int32_t n) {
    HMODULE ga;
    unsigned char *p, *end;
    MEMORY_BASIC_INFORMATION mbi;
    AowlProRow *r;
    if (n <= 0) return -1;
    if (n > AOWL_PRO_MAX_BYTES) n = AOWL_PRO_MAX_BYTES;
    r = aowl_pro_find(rva);
    if (!r || !r->used || r->len < n) return -1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return -1;
    p = (unsigned char *)ga + rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return -1;
    if (mbi.State != MEM_COMMIT) return -1;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
        return -1;
    end = (unsigned char *)mbi.BaseAddress + mbi.RegionSize;
    if (end < p || (size_t)(end - p) < (size_t)n) return -1;
    return memcmp(r->b, p, (size_t)n) == 0 ? 0 : 1;
}
""".}

proc cPrvaLiveDiffers(rva: uint32; n: int32): int32 {.
  importc: "aowl_prva_live_differs", nodecl.}

const
  RvaGateMinSig = 8'i32
    ## The shortest prologue a mod may assert. Not 1: a single byte matches
    ## thousands of functions (`0x40` opens most of them), so a one-byte
    ## "verify" is a check that passes on the wrong address. 8 is what the
    ## resolver prints anyway -- `bytes <RVA> 16` -- so declaring the full 16
    ## costs a copy-paste and this is the floor, not the recommendation.

var gRvaGateAccepted = 0
var gRvaGateRefused = 0

proc rvaGateCounts(accepted: var int; refused: var int) =
  ## For a status line. Kept as a proc so nothing outside this file writes them.
  accepted = gRvaGateAccepted
  refused = gRvaGateRefused

proc rvaOwnerOf(rva: uint32): string =
  ## The target string of a LIVE patch already installed at this RVA, or "".
  ##
  ## Exact rather than textual: every row's spec is re-parsed and its RVA
  ## compared, so `@0x6fc250` and `@0x6FC250` are one address and a decimal
  ## lookalike in a name is not. Bounded by the engine's slot capacity, which
  ## is what `gPatches` is indexed by.
  result = ""
  var k = 0
  while k < gPatches.len:
    if gPatches[k].live:
      let other = parseRvaSpec(gPatches[k].target)
      if other.isRva and other.why.len == 0 and other.rva == rva:
        return gPatches[k].target
    inc k

proc rvaGateRefusal(rs: RvaSpec; allowShared: bool): string

var gRvaGateSelfChecked = false

proc rvaGateSelfCheck() =
  ## THE GATES, PROVED TO BE ABLE TO SAY NO -- in the live client, against the
  ## real GameAssembly.dll and the real name index, once per session, the first
  ## time a mod asks for a by-RVA patch.
  ##
  ## It exists because "no mod was refused today" is not evidence that anything
  ## was checked. Three of these four probes MUST be refused, and each is
  ## refused for a different reason, so a gate that quietly stopped working is
  ## visible in the log rather than only in a raid. The fourth is a positive
  ## control: a real, unique, correctly declared target that must be ACCEPTED,
  ## which is what stops the whole set from passing by refusing everything.
  ##
  ## It writes NOTHING. `rvaGateRefusal` only reads -- the name index, the
  ## startup snapshot, and live bytes -- so a probe that a broken gate wrongly
  ## accepted still installs no detour. That is why the shared-RVA negative can
  ## safely name a real 677-owner address instead of a synthetic one.
  if gRvaGateSelfChecked:
    return
  gRvaGateSelfChecked = true
  let keepOk = gRvaGateAccepted
  let keepNo = gRvaGateRefused

  # 1. NEGATIVE -- a real, unique, correct RVA with NO declared prologue.
  #    Must be refused at gate PROLOGUE DECLARED. If this is ever accepted,
  #    every "prologue VERIFIED" line the host prints is unfalsifiable.
  let p1 = parseRvaSpec("EFT.Player::CalculateScaleValueByFov@0x6FC250/if>x")
  let r1 = (if p1.isRva and p1.why.len == 0: rvaGateRefusal(p1, false)
            else: "")
  # 2. NEGATIVE -- a real address with 677 owners (measured:
  #    il2cpp_nameindex.py shared), correctly named and correctly byte-declared,
  #    so the ONLY thing wrong with it is the blast radius. Must be refused at
  #    gate SHAREDNESS.
  let p2 = parseRvaSpec("AIDataRoomLogic::AddRoom@0x66C210/io>x" &
                        "!833D29A3A406004889511074444C8D41")
  let r2 = (if p2.isRva and p2.why.len == 0: rvaGateRefusal(p2, false)
            else: "")
  # 3. NEGATIVE -- the right address, the right bytes, a name that is NOT a key
  #    on this build (a nested type carries no namespace here). This is the
  #    historical defect itself: the FOV mod shipped this name for weeks and
  #    nothing looked it up. Must be refused at gate SHAREDNESS as UNKNOWN.
  let p3 = parseRvaSpec("EFT.Player.FirearmController::get_AimingSensitivity" &
                        "@0x7773F0/i>f!40534883EC20488B11488BD9488B82C8")
  let r3 = (if p3.isRva and p3.why.len == 0: rvaGateRefusal(p3, false)
            else: "")
  # 4. POSITIVE CONTROL -- unique, prologue correct, name a real index key.
  let p4 = parseRvaSpec("EFT.Player::CalculateScaleValueByFov@0x6FC250/if>x" &
                        "!F30F5C0D40A6EB05F30F1005A09DEB05")
  let r4 = (if p4.isRva and p4.why.len == 0: rvaGateRefusal(p4, false)
            else: "the probe spec itself would not parse")

  gRvaGateAccepted = keepOk
  gRvaGateRefused = keepNo

  var bad = 0
  if find(r1, "PROLOGUE DECLARED") < 0:
    inc bad
    fail "patch-by-RVA SELF-CHECK 1/4 FAILED: a spec with no declared " &
         "prologue was NOT refused at gate PROLOGUE DECLARED (got: " &
         (if r1.len == 0: "accepted" else: r1) & "). Nothing this host says " &
         "about a verified prologue can be believed until this passes."
  if find(r2, "SHAREDNESS") < 0:
    inc bad
    fail "patch-by-RVA SELF-CHECK 2/4 FAILED: il2cpp+0x66C210, measured to " &
         "have 677 owners, was NOT refused at gate SHAREDNESS (got: " &
         (if r2.len == 0: "accepted" else: r2) & ")."
  if find(r3, "SHAREDNESS") < 0:
    inc bad
    fail "patch-by-RVA SELF-CHECK 3/4 FAILED: a name that is not a key in " &
         "the offline index was NOT refused at gate SHAREDNESS (got: " &
         (if r3.len == 0: "accepted" else: r3) & "), so the name is being " &
         "treated as decoration and the RVA is going unchecked against it."
  # The positive control accepts two answers, and ALREADY DETOURED is one of
  # them: if this session has already patched that method, the live bytes
  # differ from the snapshot and refusing is the correct answer, not a broken
  # gate. Any other refusal means a gate is rejecting a target that is right.
  if r4.len > 0 and find(r4, "ALREADY DETOURED") < 0:
    inc bad
    fail "patch-by-RVA SELF-CHECK 4/4 FAILED (the POSITIVE control): a " &
         "unique, correctly declared, correctly named target was refused -- " &
         r4 & ". The three refusals above therefore prove nothing: a gate " &
         "that refuses everything refuses correctly by accident."
  if bad == 0:
    okLog "patch-by-RVA SELF-CHECK 4/4 passed: no-prologue REFUSED, a " &
          "677-owner address REFUSED, an unknown name REFUSED, and a real " &
          "unique target " &
          (if r4.len == 0: "ACCEPTED" else: "refused only as ALREADY DETOURED") &
          ". Read-only: no detour was installed by any of the four."

proc rvaGateRefusal(rs: RvaSpec; allowShared: bool): string =
  ## "" to accept. Anything else is the refusal, naming the gate that declined
  ## and what the caller can do about it.
  result = ""
  rvaGateSelfCheck()

  # ---- GATE 1: something must have been byte-compared -------------------
  if rs.siglen < RvaGateMinSig:
    inc gRvaGateRefused
    return "patch-by-RVA " & rs.name & " (il2cpp+0x" & hexOf(uint64(rs.rva)) &
           "): REFUSED at gate PROLOGUE DECLARED -- the spec asserts " &
           $int(rs.siglen) & " prologue byte(s) and this host requires at " &
           "least " & $int(RvaGateMinSig) & " before it writes into a game " &
           "function. Without them nothing is byte-compared, and an address " &
           "that passed only the module/page/section checks is an address " &
           "that happens to be code, not evidence that it is THIS method on " &
           "THIS build. Append !<hex> -- il2cpp_resolve.py bytes 0x" &
           hexOf(uint64(rs.rva)) & " 16 prints exactly what to paste."

  # ---- GATE 2: the address must be UNIQUE -------------------------------
  #
  # Asked of the offline name index, which is the only source on this build
  # that can answer it: the share count is frozen from the metadata at
  # generation time, and reading it touches no IL2CPP export.
  #
  # It is asked by NAME, so it also cross-checks the two halves of the spec
  # against each other: the index's RVA for `Type::Method` at the declared
  # arity must be the RVA the caller wrote. That is a check that genuinely
  # fails -- the FOV mod named the aiming-sensitivity getter
  # `EFT.Player.FirearmController::...`, which is not a key on this build (the
  # nested type carries no namespace), and this gate is what says so instead
  # of letting a name that resolves to nothing sit in a comment as "UNIQUE".
  let arity = int32(rs.kinds.len)
  var share = ShareUnknown
  var idxRva = 0'u32
  var whyShare = ""
  var fatalShare = false

  if not gNameIndex:
    whyShare = "the offline name index is OFF (`nameIndex` in " &
               "aowlspt-host.json), so this host cannot read how many " &
               "methods the IL2CPP backend folded onto this address. A " &
               "detour on a folded body fires for every one of them, and " &
               "UNKNOWN is refused rather than assumed to be one owner: turn " &
               "`nameIndex` on, or append !shared to say the blast radius is " &
               "understood and wanted."
  else:
    idxRva = nameIndexRva(rs.name, arity, share)
    if idxRva == 0'u32:
      whyShare = "the name index has NO entry for " & rs.name & " at arity " &
                 $int(arity) & " (the declared shape says " & $int(arity) &
                 " argument(s)), so the share count is UNKNOWN. Unknown is a " &
                 "refusal, not a probably-safe: the key may be spelled for a " &
                 "different build, the arity may not match the shape, or the " &
                 "key may have been DROPPED at generation because two types " &
                 "produce it. Check it offline with il2cpp_nameindex.py lookup."
    elif idxRva != rs.rva:
      # NEVER overridable. This is not a sharedness question any more: the two
      # halves of the caller's own spec disagree, and one of them is wrong.
      fatalShare = true
      whyShare = "the spec says il2cpp+0x" & hexOf(uint64(rs.rva)) &
                 " but the offline name index maps " & rs.name & "/" &
                 $int(arity) & " to il2cpp+0x" & hexOf(uint64(idxRva)) &
                 ". One of the two is stale. Nothing is patched on a spec " &
                 "that contradicts itself, and !shared does not override " &
                 "this: it is an override for a KNOWN blast radius, not for " &
                 "a wrong address."
    elif share >= 2'u32:
      whyShare = "the IL2CPP backend folded " & $int(share) & " methods onto " &
                 "this one address. A detour here fires for all " &
                 $int(share) & " of them, including whichever unrelated " &
                 "method in whichever assembly happens to have an identical " &
                 "body. Detour a unique address, or append !shared if every " &
                 "one of those firings is wanted."
    elif share != 1'u32:
      whyShare = "the index answered with share count " & $int(share) &
                 ", which is neither UNKNOWN(0) nor a real owner count. " &
                 "Refused rather than interpreted."

  if whyShare.len > 0:
    if fatalShare or not allowShared:
      inc gRvaGateRefused
      return "patch-by-RVA " & rs.name & " (il2cpp+0x" &
             hexOf(uint64(rs.rva)) & "): REFUSED at gate SHAREDNESS -- " &
             whyShare
    warn "patch-by-RVA " & rs.name & " (il2cpp+0x" & hexOf(uint64(rs.rva)) &
         "): the SHAREDNESS gate was OVERRIDDEN with !shared. What it " &
         "actually found: " & whyShare & " Every method on this address will " &
         "fire this handler."

  # ---- GATE 3: nobody may already own the function ----------------------
  let live = cPrvaLiveDiffers(rs.rva, rs.siglen)
  if live != 0'i32:
    inc gRvaGateRefused
    let owner = rvaOwnerOf(rs.rva)
    if live == 1'i32:
      return "patch-by-RVA " & rs.name & " (il2cpp+0x" &
             hexOf(uint64(rs.rva)) & "): REFUSED at gate ALREADY DETOURED -- " &
             "the LIVE first " & $int(rs.siglen) & " bytes no longer match " &
             "the startup snapshot, which the declared prologue DID match a " &
             "moment ago, so something has written a jump over this " &
             "function's entry" &
             (if owner.len > 0: " -- this host's own table says it is " & owner
              else: " (no patch of this host's owns it, so it is another " &
                    "feature's binder or something outside this process)") &
             ". A second detour here would overwrite the first's trampoline " &
             "and kill it with no error anywhere. Ride the existing detour " &
             "as a drain instead."
    return "patch-by-RVA " & rs.name & " (il2cpp+0x" & hexOf(uint64(rs.rva)) &
           "): REFUSED at gate ALREADY DETOURED -- the live bytes CANNOT BE " &
           "COMPARED against the startup snapshot (no snapshot row, the " &
           "module unmapped, or the page not readable as 16 whole bytes). " &
           "That is an inconclusive answer, and an inconclusive answer to " &
           "'does anything already own this function' is refused, not passed."

  inc gRvaGateAccepted
  okLog "patch-by-RVA " & rs.name & " (il2cpp+0x" & hexOf(uint64(rs.rva)) &
        "): gates PASSED -- prologue " & $int(rs.siglen) &
        " byte(s) verified against the startup snapshot, name index says " &
        (if idxRva == 0'u32: "OVERRIDDEN" else: $int(share) & " owner(s)") &
        ", and the live entry still matches the snapshot so no other detour " &
        "owns it."
