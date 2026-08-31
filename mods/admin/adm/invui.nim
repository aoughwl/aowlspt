## The nimony face of `abi/aowlspt_invui.h` -- the BACKEND half of the native
## inventory / item-spawner screen.
##
## ## What this is and what it is not
##
## It is NOT a second item spawner. `aowl.items` (provided by `mods/tarkov`) is
## still the only thing that mints anything, and `spawnInto` is still the only
## thing that touches a profile. This file is a TRANSPORT and a READBACK:
##
##   * it drains three request kinds out of the shared region -- fill the stash
##     column, fill the inventory column, mint one template -- and answers each
##     by calling `aowl.items`;
##   * for a mint it asks `aowl.items` how many of that template the profile
##     held BEFORE and again AFTER, and publishes those two numbers. The verdict
##     is derived from them inside `aowl_invui_mint_done`, in one place, so
##     nothing on this side can spell a PASS.
##
## ## Why it lives in `mods/admin` and not in `mods/tarkov`
##
## For the same reason the F6 spawner's drain does, and the reason is measured:
## `capability.invoke` REFUSES on `sideClient` because the client host has no
## mod set to resolve a provider against. The native screen runs in the GAME
## process, which is `sideClient`; the provider runs in the BACKEND process.
## `Local\aowlspt_invui_v1` is a session-local file mapping and both processes
## are in one session, so one region joins them. This mod is already loaded on
## both sides for exactly this reason, so adding a second drain here costs one
## more `if pending == 0: return` per tick and no new process, no new thread and
## no new detour.
##
## ## Cost when nothing is happening
##
## Three shared-memory integer compares. `*Pending` returns 0 unless the native
## screen has asked for something, and the screen only asks when the player
## opens it or types. There is no polling of the database, no scan, and no
## cross-mod call on an idle tick.

{.emit: """
#include "aowlspt_invui.h"

/* Character-at accessors. `aowl_iu_get_str` in the header is the right C API
 * and the wrong nimony API: nimony has no `cstring` out-buffer idiom that
 * survives the FFI cleanly, and `adm/shared.nim` already established the
 * char-at pattern for `spawnQuery` for this exact reason. These are thin, they
 * clamp, and they live HERE rather than in the ABI header so the header keeps
 * one string API instead of two. */
static int32_t aowl_iu_query_at(AowlInvUiShared* s, int32_t i) {
    if (!aowl_invui_compatible(s)) return 0;
    if (i < 0 || i >= AOWL_IU_QUERY_LEN) return 0;
    return (int32_t)(unsigned char)s->query[i];
}
static int32_t aowl_iu_query_len(AowlInvUiShared* s) {
    LONG n;
    if (!aowl_invui_compatible(s)) return 0;
    n = s->queryLen;
    if (n < 0) return 0;
    if (n > AOWL_IU_QUERY_LEN - 1) return AOWL_IU_QUERY_LEN - 1;
    return (int32_t)n;
}
static int32_t aowl_iu_minttpl_at(AowlInvUiShared* s, int32_t i) {
    if (!aowl_invui_compatible(s)) return 0;
    if (i < 0 || i >= AOWL_IU_TPL_LEN) return 0;
    return (int32_t)(unsigned char)s->mintTpl[i];
}
static int32_t aowl_iu_tpl_cap(void)  { return AOWL_IU_TPL_LEN; }
static int32_t aowl_iu_max_rows(void) { return AOWL_IU_MAX_ROWS; }
""".}

type
  InvUiRegion* = pointer   ## an `AowlInvUiShared*`, opaque on this side

proc cIuMap(): InvUiRegion {.importc: "aowl_invui_map", nodecl.}
proc cIuCompatible(s: InvUiRegion): int32 {.
  importc: "aowl_invui_compatible", nodecl.}

proc cIuStashPending(s: InvUiRegion): int32 {.
  importc: "aowl_invui_stash_pending", nodecl.}
proc cIuInvPending(s: InvUiRegion): int32 {.
  importc: "aowl_invui_inv_pending", nodecl.}
proc cIuMintPending(s: InvUiRegion): int32 {.
  importc: "aowl_invui_mint_pending", nodecl.}

proc cIuQueryAt(s: InvUiRegion; i: int32): int32 {.
  importc: "aowl_iu_query_at", nodecl.}
proc cIuQueryLen(s: InvUiRegion): int32 {.
  importc: "aowl_iu_query_len", nodecl.}
proc cIuMintTplAt(s: InvUiRegion; i: int32): int32 {.
  importc: "aowl_iu_minttpl_at", nodecl.}
proc cIuTplCap(): int32 {.importc: "aowl_iu_tpl_cap", nodecl.}
proc cIuMaxRows(): int32 {.importc: "aowl_iu_max_rows", nodecl.}

proc cIuMintCount(s: InvUiRegion): int32 {.
  importc: "aowl_invui_get_mint_count", nodecl.}
proc cIuMintCondition(s: InvUiRegion): int32 {.
  importc: "aowl_invui_get_mint_condition", nodecl.}

proc cIuStashBegin(s: InvUiRegion) {.importc: "aowl_invui_stash_begin", nodecl.}
proc cIuInvBegin(s: InvUiRegion) {.importc: "aowl_invui_inv_begin", nodecl.}
proc cIuStashAdd(s: InvUiRegion; tpl, name: cstring): int32 {.
  importc: "aowl_invui_stash_add", nodecl.}
proc cIuInvAdd(s: InvUiRegion; tpl, name: cstring; qty: int32): int32 {.
  importc: "aowl_invui_inv_add", nodecl.}
proc cIuStashMatchedSet(s: InvUiRegion; n: int32) {.
  importc: "aowl_invui_stash_matched_set", nodecl.}
proc cIuInvTotalSet(s: InvUiRegion; n: int32) {.
  importc: "aowl_invui_inv_total_set", nodecl.}
proc cIuSetNote(s: InvUiRegion; msg: cstring) {.
  importc: "aowl_invui_set_note", nodecl.}
proc cIuStashDone(s: InvUiRegion; req: int32) {.
  importc: "aowl_invui_stash_done", nodecl.}
proc cIuInvDone(s: InvUiRegion; req: int32) {.
  importc: "aowl_invui_inv_done", nodecl.}
proc cIuMintDone(s: InvUiRegion; req, before, after, readable: int32;
                 msg: cstring) {.importc: "aowl_invui_mint_done", nodecl.}

# ---------------------------------------------------------------------------
# The nimony surface. Every one of these is bounded by the region's own
# capacity, never by a length the region supplied.
# ---------------------------------------------------------------------------

proc iuMap*(): InvUiRegion =
  ## Map (or create) the region. NULL only if the OS refused, which is a
  ## no-screen outcome and never a crash.
  cIuMap()

proc iuCompatible*(s: InvUiRegion): bool =
  ## Magic, version AND `sizeof(AowlIuRow)` all agree with this build. A
  ## mismatch is refused by name rather than parsed: another build's row table
  ## read as ours yields plausible garbage item names, which is worse than an
  ## empty screen.
  if s == nil: false else: cIuCompatible(s) != 0'i32

proc iuStashPending*(s: InvUiRegion): int32 =
  if s == nil: 0'i32 else: cIuStashPending(s)
proc iuInvPending*(s: InvUiRegion): int32 =
  if s == nil: 0'i32 else: cIuInvPending(s)
proc iuMintPending*(s: InvUiRegion): int32 =
  if s == nil: 0'i32 else: cIuMintPending(s)

proc iuQuery*(s: InvUiRegion): string =
  ## The typed query. Stops at the first NUL and is capped at the buffer's own
  ## capacity, so a `queryLen` that overstates the content yields a SHORT string
  ## rather than a walk off the end of the section.
  result = ""
  if s == nil: return
  var n = cIuQueryLen(s)
  var i = 0'i32
  while i < n:
    let c = cIuQueryAt(s, i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuMintTpl*(s: InvUiRegion): string =
  ## The template id the screen asked to mint. Capped at `AOWL_IU_TPL_LEN`.
  result = ""
  if s == nil: return
  let cap = cIuTplCap()
  var i = 0'i32
  while i < cap:
    let c = cIuMintTplAt(s, i)
    if c <= 0'i32 or c > 255'i32: break
    result.add char(c)
    i = i + 1'i32

proc iuMintCount*(s: InvUiRegion): int =
  if s == nil: 1 else: int(cIuMintCount(s))
proc iuMintCondition*(s: InvUiRegion): int =
  if s == nil: 100 else: int(cIuMintCondition(s))
proc iuMaxRows*(): int = int(cIuMaxRows())

proc iuStashBegin*(s: InvUiRegion) =
  if s != nil: cIuStashBegin(s)
proc iuInvBegin*(s: InvUiRegion) =
  if s != nil: cIuInvBegin(s)

proc iuStashAdd*(s: InvUiRegion; tpl, name: string): bool =
  ## Returns whether the row LANDED. A full table is a refusal the caller counts,
  ## never a silent drop -- a dropped row is the whole difference between the
  ## returned count and the matched count.
  if s == nil: return false
  var t = tpl
  var n = name
  cIuStashAdd(s, toCString(t), toCString(n)) != 0'i32

proc iuInvAdd*(s: InvUiRegion; tpl, name: string; qty: int): bool =
  if s == nil: return false
  var t = tpl
  var n = name
  cIuInvAdd(s, toCString(t), toCString(n), int32(qty)) != 0'i32

proc iuStashMatched*(s: InvUiRegion; n: int) =
  if s != nil: cIuStashMatchedSet(s, int32(n))
proc iuInvTotal*(s: InvUiRegion; n: int) =
  if s != nil: cIuInvTotalSet(s, int32(n))

proc iuNote*(s: InvUiRegion; text: string) =
  if s == nil: return
  var t = text
  cIuSetNote(s, toCString(t))

proc iuStashDone*(s: InvUiRegion; req: int32) =
  if s != nil: cIuStashDone(s, req)
proc iuInvDone*(s: InvUiRegion; req: int32) =
  if s != nil: cIuInvDone(s, req)

proc iuMintDone*(s: InvUiRegion; req: int32; before, after: int;
                 readable: bool; text: string) =
  ## Publish the mint's READBACK. `before`/`after` are counts of the minted
  ## template in the profile either side of the spawn; the verdict is computed
  ## from them by the header, not here, so no call site can hand-write a PASS.
  ## `readable = false` is INCONCLUSIVE -- "I could not look" -- and is
  ## deliberately not a FAIL.
  if s == nil: return
  var t = text
  cIuMintDone(s, req, int32(before), int32(after),
              (if readable: 1'i32 else: 0'i32), toCString(t))
