## aowl.loadammoanim — first-person magazine loading animations.
##
##     aowl build-mod mods/loadammoanim
##
## A port of Manimal's **ManimalAmmoLoadingAnimations** (v1.6.0, MIT) to the
## post-1.0 IL2CPP client. The upstream animation assets are reused verbatim
## under their MIT licence; `LICENSE.upstream.txt` is the upstream copy.
##
## ---------------------------------------------------------------------------
## WHAT THIS IS, AND WHAT IT IS NOT
## ---------------------------------------------------------------------------
##
## Vanilla EFT has **no** first-person magazine-loading animation at all. The
## upstream mod's entire visible behaviour comes out of a bundle it ships
## (`stanags_container.bundle`: a hand-authored Animator graph plus mag meshes),
## dispatched through a **runtime-injected managed subclass** of
## `Player.UsableItemController` whose `vmethod_0` the engine calls, routed by
## **generic** controller-swap methods instantiated with that injected type.
##
## Neither of those is reachable here. Constructing a valid `Il2CppClass` is
## unverified on this build, and a generic instantiation needs a real
## `Il2CppClass` for the type argument and a non-NULL `MethodInfo*`. So this is
## deliberately **not** a 1:1 port. It is an approximation that skips the
## controller system entirely:
##
##   * detect the load flow at its real (deobfuscated) entry point,
##   * instantiate the upstream prefab as a plain GameObject through the game's
##     own EasyAssets pipeline,
##   * enable the mesh matching the magazine being loaded,
##   * drive that prefab's Animator directly by verified static RVA.
##
## **What is lost relative to upstream, stated plainly:** no Fika co-op sync
## (upstream broadcasts session start/stop/mesh-swap as packets), no
## ContinuousLoadAmmo compatibility, and the prefab is parented by us rather
## than positioned for free by the controller system — so first-person
## placement is ours to get right and is the one part that needs live
## iteration rather than offline proof.
##
## A pleasant consequence of dropping the controller swap: upstream needs
## null-guard prefixes on `ProceduralWeaponAnimation::ProcessEffectors` and
## `Player::VisualPass` purely because the swap leaves `WeaponRootAnim` briefly
## null. **We never swap controllers, so that window does not exist and those
## guards are not installed.** That also keeps us clear of the measured
## landmine that several `ProceduralWeaponAnimation` property names are
## MIS-ASSIGNED in SPT's deobfuscation — this mod reads no PWA property at all.
##
## ---------------------------------------------------------------------------
## EVERY ADDRESS AND OFFSET, AND HOW IT WAS OBTAINED
## ---------------------------------------------------------------------------
##
## Instrument for all of it: `tools/il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll
## .cache\global-metadata.dec.dat <verb>` and `tools/fldoff.py ... fields <Type>`
## against build 1.1.0.1.46777. Nothing below is guessed and nothing is trusted
## by name alone.
##
## THE TRIGGER. Upstream patches `Player.PlayerInventoryController.Class1204`
## — an obfuscated Mono name that returns **zero hits** across all 31,282 types
## here. The real type was re-identified **by signature and field shape**, not
## by name: `LoadMagazineProcess` (type 6713, `Assembly-CSharp.dll`) has
## `Task<IResult> Start()`, a private `float _loadOneAmmoSpeed`, a `Magazine
## _magazine`, and `<LoadProcess>g__CoolDown|18_0()` for the per-bullet wait —
## exactly upstream's `Start`, `Float_0`, `MagazineItemClass` and `method_5`.
## That correspondence is the evidence; the name is only a label.
##
##   RVA         method                                  owners  verified
##   0x768F50    LoadMagazineProcess::Start              UNIQUE  prologue ok
##   0x769260    LoadMagazineProcess::RaiseLoadEventArgs UNIQUE  prologue ok
##   0x769160    LoadMagazineProcess::Abort              UNIQUE  prologue ok
##   0x938430    EFT.ObjectsFactory::.ctor               UNIQUE  prologue ok
##   0x93AB40    EFT.ObjectsFactory::InstantiateWithoutPool UNIQUE prologue ok
##   0x52ADDA0   UnityEngine.Object::Instantiate(o,t,b)  UNIQUE  prologue ok
##   0x524A680   UnityEngine.Animator::Play(string)      UNIQUE  prologue ok
##   0x52495C0   UnityEngine.Animator::SetBool           SHARED(2)  CALL ONLY
##   0x524B000   UnityEngine.Animator::Update(float)     UNIQUE  prologue ok
##
## Every one of those was byte-checked to confirm it is **not** `C2 00 00` —
## this build's universal empty-body stub, shared by 6,438 methods. A stub that
## passes a signature check is the worst case available, so the check is on the
## bytes, not on the shape.
##
## `Animator::SetBool` is SHARED by 2 owners. It is **called, never detoured**:
## calling a shared RVA is correct code for the receiver passed; detouring one
## has unbounded blast radius. The only two RVAs this mod DETOURS
## (`LoadMagazineProcess::Start`, `ObjectsFactory::.ctor`) are both UNIQUE.
##
## FIELD OFFSETS, from `Il2CppMetadataRegistration.fieldOffsets`:
##
##   LoadMagazineProcess._magazine           +0x18   Magazine
##   LoadMagazineProcess._loadOneAmmoSpeed   +0x30   float
##   Item.<Template>k__BackingField          +0x60   ItemTemplate
##   ItemTemplate.<_id>k__BackingField       +0xE0   MongoID (inline struct)
##   MongoID._stringID                       +0x10   string   (struct-relative)
##
## The last one is the only *inferred* step: IL2CPP reports value-type field
## offsets including the 0x10 object header, so an inline struct's field sits
## at `structBase + (reported - 0x10)`, putting the tpl id string at
## `ItemTemplate + 0xF0`. That inference is not trusted — it is **checked**:
## a magazine template id is always 24 hexadecimal characters, so `read` mode
## requires exactly that and REFUSES otherwise. If the offset is wrong we get a
## refusal naming it, not a plausible-looking wrong id.
##
## ---------------------------------------------------------------------------
## THE BUNDLE-KEY PROBLEM, AND THE DOUBLE-DETOUR IT WOULD HAVE CAUSED
## ---------------------------------------------------------------------------
##
## We cannot ADD a bundle key. The game constructs one `EasyBundle` per entry
## in BSG's own manifest, and `mods/textures/redirect.nim` can only rewrite an
## existing key's `_path`. So our bundle has to ride an existing vanilla key,
## and that key's real asset is unavailable while this feature is on — which is
## exactly why the feature is default-OFF and the key is a config choice rather
## than a constant.
##
## The redirect itself is performed by **`mods/textures`**, not here.
## `mods/textures/redirect.nim` already owns a prefix on
## `Diz.Resources.EasyBundle::Load` @0x2772CC0, and **two detours on one
## function overwrite each other's trampoline and silently kill the first**.
## So this mod never touches that RVA; it rides the detour that already exists,
## by asking the operator to drop our file into the textures `bundleRoot` under
## our chosen key. That is the "ride an existing detour as a drain" rule
## applied literally.
##
## ---------------------------------------------------------------------------
## SAFETY
## ---------------------------------------------------------------------------
##
## Prologue byte-verify before any bind or call; `VirtualQuery` on every hop,
## and `a->b->c` is three checks rather than one; ONE `aowl_p_p_seh` (the
## host's — this adds none, because that guard is NOT re-entrant and a nested
## one DISARMS the outer); capped iteration everywhere; flag-gated default-OFF;
## self-disable after `maxFaults`; no per-frame managed allocation (state-name
## strings are allocated once at arm time, not per frame).
##
## Unity FAKE NULL is handled explicitly: a destroyed object stays readable
## with `m_CachedPtr` zeroed and only dies on the next internal call, so
## readability is NOT liveness. Every spawned instance is checked for a
## non-zero `m_CachedPtr` before it is driven.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import aowlspt/callrva
import aowlspt/server
import aowlspt/settings

const
  ModGuid    = "aowl.loadammoanim"
  ModName    = "Ammo Loading Animations"
  ModAuthor  = "aowlspt (port of Manimal's ManimalAmmoLoadingAnimations, MIT)"
  ModVersion = "0.1.0"

  ## The escalation ladder. `mode` in config.json.
  ModeOff     = 0
  ModeProbe   = 1
  ModeRead    = 2
  ModeSpawn   = 3
  ModeAnimate = 4

  ## ---- detour targets (both UNIQUE; nothing shared is ever detoured) ----

  ## `LoadMagazineProcess::Start` — the real equivalent of upstream's
  ## `Class1204.Start`. Instance, arity 0, returns `Task<IResult>` -> shape
  ## `i>o`. The shape is DECLARED because an RVA patch has no `MethodInfo` to
  ## derive it from and a guessed frame shape is a silently wrong hook.
  TgtStart    = "LoadMagazineProcess::Start@0x768F50/i>o" &
                "!40534883EC70803D3FF3940600488BD9"
  TgtStartRva = 0x768F50'u32
  StartProlog: array[16, uint8] = [
    0x40'u8, 0x53, 0x48, 0x83, 0xEC, 0x70, 0x80, 0x3D,
    0x3F,    0xF3, 0x94, 0x06, 0x00, 0x48, 0x8B, 0xD9]

  ## `EFT.ObjectsFactory::.ctor(IEasyAssets, ItemTemplates, IRaidCounter)`.
  ##
  ## THE LATCH. `EasyAssets` is a public INITONLY field at `+0x20` on
  ## `ObjectsFactory`, but the *holder* of an `ObjectsFactory` is not
  ## identifiable offline: `get_ObjectsFactory` returns zero hits across all
  ## 31,282 types and this build has no `PoolManager` at all (upstream's
  ## `Singleton<PoolManagerClass>.Instance.EasyAssets` therefore has no
  ## equivalent to resolve).
  ##
  ## Rather than guess an offset that could read null, we take the pointer from
  ## a place it is *known* live: the constructor's own arguments. This is the
  ## "walk from a verified live object" rule — the object is verified because
  ## the engine is in the act of constructing it. Instance, 3 object args, void
  ## -> shape `iooo>x`.
  ## `LoadMagazineProcess::RaiseLoadEventArgs(CommandStatus)` — the session's
  ## own terminal signal, raised however the load ends. Instance, one enum
  ## argument, void -> shape `ii>x`.
  TgtEnd    = "LoadMagazineProcess::RaiseLoadEventArgs@0x769260/ii>x" &
              "!48895C240848896C2410488974241848"
  TgtEndRva = 0x769260'u32
  EndProlog: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C,
    0x24,    0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x48]

  ## THE BROAD PROBE. `LoadMagazineProcess::.ctor(InventoryController,
  ## Magazine, Ammo, int, bool, float)` @0x768D40 — measured UNIQUE
  ## (owners=1) by `il2cpp_resolve.py shared 0x768d40`, real body (bytes
  ## `48 89 5C 24 08 57 ...`, NOT the `C2 00 00` universal empty stub).
  ##
  ## It exists to make one distinction that `Start` alone cannot: whether
  ## `LoadMagazineProcess` is CONSTRUCTED AT ALL during the load the player
  ## performed. If the ctor fires and `Start` does not, the type is right and
  ## the entry point is wrong. If NEITHER fires, the whole type is not on the
  ## path the player took and the identification-by-shape was wrong. Those are
  ## opposite fixes, and before this probe existed the log could not tell them
  ## apart.
  ##
  ## It only ever does `inc`. It dereferences nothing, calls nothing and
  ## writes nothing, on any rung.
  ##
  ## Shape: instance + 3 object args + int + bool + float, void return.
  TgtProcCtor    = "LoadMagazineProcess::.ctor@0x768D40/ioooiif>x" &
                   "!48895C2408574883EC208B05F0D79406"
  TgtProcCtorRva = 0x768D40'u32
  ProcCtorProlog: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83,
    0xEC,    0x20, 0x8B, 0x05, 0xF0, 0xD7, 0x94, 0x06]

  TgtFactoryCtor    = "EFT.ObjectsFactory::.ctor@0x938430/iooo>x" &
                      "!48895C240848896C2410488974241857"
  TgtFactoryCtorRva = 0x938430'u32
  FactoryCtorProlog: array[16, uint8] = [
    0x48'u8, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C,
    0x24,    0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57]

  ## ---- call targets (never detoured) ----
  ## Each signature is the 16 measured prologue bytes, and each was checked to
  ## be something other than `C2 00 00`.
  RvaInstantiateNoPool = 0x93AB40'u32
  SigInstantiateNoPool = "48895C2408574883EC40803D21E27706"

  RvaAnimPlay   = 0x524A680'u32
  SigAnimPlay   = "4883EC38F30F101DE0C8360141B8FFFF"

  ## SHARED by 2 owners. Called, never detoured.
  RvaAnimSetBool = 0x52495C0'u32
  SigAnimSetBool = "48895C24084889742410574883EC2048"

  RvaAnimUpdate = 0x524B000'u32
  SigAnimUpdate = "40534883EC30488B05FB70E801488BD9"

  ## ---- field offsets (measured; see the header) ----
  LmpMagazineOff = 0x18'u   ## LoadMagazineProcess._magazine
  LmpSpeedOff    = 0x30'u   ## LoadMagazineProcess._loadOneAmmoSpeed
  ItemTemplateOff = 0x60'u  ## Item.<Template>k__BackingField
  TplIdStringOff  = 0xF0'u  ## ItemTemplate + MongoID._stringID (see header)

  ## `System.String` on 64-bit: header 16 bytes, then length (int32) at 0x10
  ## and UTF-16 characters at 0x14. Self-check for the resolver:
  ## `_stringLength@0x10`, `_firstChar@0x14`.
  StrLenOff  = 0x10'u
  StrCharOff = 0x14'u

  ## A magazine template id is a MongoID: exactly 24 hexadecimal characters.
  ## This is the check that makes the inline-struct offset inference
  ## falsifiable rather than assumed.
  TplIdChars = 24

  ## Caps, not expectations.
  ## Heartbeat cadence for the counter report. Slow enough not to be noise in a
  ## 40-minute raid, fast enough that a player who loads one magazine sees the
  ## consequence within half a minute.
  ReportEveryMs: int64 = 30000

  MaxSessionsLogged = 24
  MaxMeshEntries    = 32

type
  ## One magazine template id -> the GameObject name to enable inside the
  ## bundle prefab. Table carried over verbatim from upstream's
  ## `MagAnimLookup`; the mesh names must match the bundle exactly.
  MeshEntry = object
    tpl:  string
    mesh: string

const
  FallbackMesh = "stanag_MESH"
  MeshTable: array[17, MeshEntry] = [
    MeshEntry(tpl: "55d4887d4bdc2d962f8b4570", mesh: "stanag_MESH"),
    MeshEntry(tpl: "544a37c44bdc2d25388b4567", mesh: "stanag_60_MESH"),
    MeshEntry(tpl: "5c6592372e221600133e47d7", mesh: "stanag_100_MESH"),
    MeshEntry(tpl: "5aaa5e60e5b5b000140293d6", mesh: "pmag_10_MESH"),
    MeshEntry(tpl: "5448c1d04bdc2dff2f8b4569", mesh: "pmag_20_MESH"),
    MeshEntry(tpl: "5aaa5dfee5b5b000140293d3", mesh: "pmag_MESH"),
    MeshEntry(tpl: "5d1340b3d7ad1a0b52682ed7", mesh: "pmag_FDE_MESH"),
    MeshEntry(tpl: "544a378f4bdc2d30388b4567", mesh: "pmag_40_MESH"),
    MeshEntry(tpl: "5d1340bdd7ad1a0e8d245aab", mesh: "pmag_40_FDE_MESH"),
    MeshEntry(tpl: "55802d5f4bdc2dac148b458e", mesh: "pmag_window_MESH"),
    MeshEntry(tpl: "5d1340cad7ad1a0b0b249869", mesh: "pmag_window_FDE_MESH"),
    MeshEntry(tpl: "5c6d42cb2e2216000e69d7d1", mesh: "stanag_hk_polymer_MESH"),
    MeshEntry(tpl: "5c05413a0db834001c390617",
              mesh: "stanag_hk_416_steel_maritime_MESH"),
    MeshEntry(tpl: "5c6d450c2e221600114c997d", mesh: "stanag_hk_gen2_MESH"),
    MeshEntry(tpl: "5c6d46132e221601da357d56", mesh: "stanag_troy_battlemag_MESH"),
    MeshEntry(tpl: "61840bedd92c473c77021635", mesh: "stanag_mk16_MESH"),
    MeshEntry(tpl: "61840d85568c120fdd2962a5", mesh: "stanag_mk16_MESH")]

# ---------------------------------------------------------------------------
# Native shims
# ---------------------------------------------------------------------------
#
# Prefixed `aowl_lam_*` (Load Ammo aniM) so they cannot collide with any other
# mod's shims if these land in the same compilation unit.
#
# Every dereference on the hook path goes through `aowl_lam_readable`, which
# answers committed-and-readable out to `n` bytes without leaving the region
# the query answered for. `this -> _magazine -> Template -> _id` is FOUR hops
# and therefore four checks.

{.emit: """
#include <windows.h>
#include <string.h>

static int aowl_lam_readable(const void* p, int n) {
  MEMORY_BASIC_INFORMATION mbi;
  if (!p || n <= 0) return 0;
  if (VirtualQuery(p, &mbi, sizeof(mbi)) != sizeof(mbi)) return 0;
  if (mbi.State != MEM_COMMIT) return 0;
  if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
  {
    const unsigned char* base = (const unsigned char*)mbi.BaseAddress;
    const unsigned char* q    = (const unsigned char*)p;
    SIZE_T avail = mbi.RegionSize - (SIZE_T)(q - base);
    if (avail < (SIZE_T)n) return 0;
  }
  return 1;
}

static void* aowl_lam_readptr(const void* p) {
  if (!aowl_lam_readable(p, 8)) return 0;
  return *(void* const*)p;
}

static int aowl_lam_readi32(const void* p, int* out) {
  if (!aowl_lam_readable(p, 4)) return 0;
  *out = *(const int*)p;
  return 1;
}

static int aowl_lam_readf32(const void* p, float* out) {
  if (!aowl_lam_readable(p, 4)) return 0;
  *out = *(const float*)p;
  return 1;
}

static int aowl_lam_readmem(const void* p, unsigned char* out, int n) {
  if (!aowl_lam_readable(p, n)) return 0;
  memcpy(out, p, (size_t)n);
  return 1;
}

static void* aowl_lam_rva(unsigned int rva) {
  HMODULE h = GetModuleHandleA("GameAssembly.dll");
  if (!h) return 0;
  return (void*)((unsigned char*)h + rva);
}

/* One UTF-16 unit out of a managed string's character run, as an int. -1 when
 * the read refuses. Callers cap the index; this caps the dereference. */
static int aowl_lam_strchar(const void* chars, int i) {
  const unsigned short* c = (const unsigned short*)chars;
  if (!aowl_lam_readable(c + i, 2)) return -1;
  return (int)c[i];
}
""".}

proc lamReadable(p: Il2CppPtr; n: int32): int32 {.importc: "aowl_lam_readable", nodecl.}
proc lamReadPtr(p: Il2CppPtr): Il2CppPtr {.importc: "aowl_lam_readptr", nodecl.}
proc lamReadI32(p: Il2CppPtr; outv: ptr int32): int32 {.importc: "aowl_lam_readi32", nodecl.}
proc lamReadF32(p: Il2CppPtr; outv: ptr float32): int32 {.importc: "aowl_lam_readf32", nodecl.}
proc lamReadMem(p, outp: Il2CppPtr; n: int32): int32 {.importc: "aowl_lam_readmem", nodecl.}
proc lamRva(rva: uint32): Il2CppPtr {.importc: "aowl_lam_rva", nodecl.}
proc lamStrChar(chars: Il2CppPtr; i: int32): int32 {.importc: "aowl_lam_strchar", nodecl.}

proc at(p: Il2CppPtr; off: uint): Il2CppPtr =
  cast[Il2CppPtr](cast[uint](p) + off)

# ---------------------------------------------------------------------------
# Mod state
# ---------------------------------------------------------------------------

var
  gEnabled     = false
  gMode        = ModeOff
  gBundlePath  = ""
  gHijackKey   = ""
  gDrawClipSec = 0.867
  gPutAwayMax  = 1.5
  gMaxFaults   = 8
  gArmDelayMs: int64 = 12000
  gLogSessions = true

  gRt: Il2Cpp
  gLoadedAtMs: int64 = 0
  gArmed    = false
  gArmTried = false
  gRetired  = false

  ## The latch. Filled by the `ObjectsFactory::.ctor` prefix.
  gFactory:    Il2CppPtr = cast[Il2CppPtr](0)
  gEasyAssets: Il2CppPtr = cast[Il2CppPtr](0)
  gLatched  = false

  ## Call targets, declared once at module scope: verification is capture-once
  ## and cached, so the prologue compare is paid on the first call and never
  ## again.
  tInstantiate: RvaTarget
  tAnimPlay:    RvaTarget
  tAnimSetBool: RvaTarget
  tAnimUpdate:  RvaTarget

  ## Counters — the acceptance instrument. Every one of these is incremented
  ## BEFORE the step that could fault, or not at all: a caught fault unwinds
  ## the entire guarded body silently, so a counter bumped afterwards would
  ## under-report exactly the cases that matter.
  gStartFires:   int64 = 0   ## LoadMagazineProcess::Start prefix firings
  gCtorFires:    int64 = 0   ## LoadMagazineProcess::.ctor prefix firings (the
                             ## broad probe: strictly earlier and broader than
                             ## Start, so ctor>0 with start==0 is a DIFFERENT
                             ## diagnosis from both being 0)
  gSessions:     int64 = 0   ## sessions we accepted and began
  gTplRead:      int64 = 0   ## magazine template ids successfully read
  gTplRefused:   int64 = 0   ## tpl id read that failed the 24-hex-char check
  gMeshHits:     int64 = 0   ## tpl ids that matched the mesh table
  gMeshFallback: int64 = 0   ## tpl ids that fell back to stanag_MESH
  gSpawned:      int64 = 0   ## prefab instances created
  gSpawnRefused: int64 = 0   ## spawn attempts refused (no latch, no target)
  gAnimDriven:   int64 = 0   ## sessions the animator was actually driven for
  gTeardowns:    int64 = 0   ## sessions torn down cleanly
  gFaults:       int64 = 0
  gUnreadable:   int64 = 0
  gFakeNull:     int64 = 0   ## instances whose m_CachedPtr had gone zero
  gSessionsLogged = 0

  ## ---- the reporting instrument (see `report`) ----
  gCtorHooked   = false   ## did the broad probe actually install?
  gFirstLogged  = false   ## has the unconditional FIRST-FIRING line printed?
  gLastReportMs: int64 = 0
  gLastReport   = ""      ## last heartbeat text, so an UNCHANGED state is
                          ## printed on the slow cadence and a CHANGED one
                          ## immediately.

  ## The live session. Exactly one at a time: this is a single-player client
  ## and upstream's per-player dictionary exists only for Fika, which we do not
  ## carry.
  gInSession    = false
  gSessionTpl   = ""
  gSessionMesh  = ""
  gSessionSpeed = 1.0
  gInstance: Il2CppPtr = cast[Il2CppPtr](0)
  gSessionStartedMs: int64 = 0
  gTimedOut: int64 = 0   ## sessions closed by the safety cap, not by the end
                         ## hook. A non-zero value here means the terminal
                         ## signal is not arriving and the model is wrong.

proc fault(): bool =
  ## Rule 6. Returns whether the feature is now retired.
  inc gFaults
  if not gRetired and gFaults >= int64(gMaxFaults):
    gRetired = true
    warn "loadammoanim  RETIRED after " & $gMaxFaults & " faults " &
         "(self-disable, rule 6). The hooks stay installed and keep counting; " &
         "nothing will be dereferenced, called or written again this session. " &
         "Vanilla magazine loading is unaffected. See faults/unreadable in " &
         "loadAmmoAnimStats."
  result = gRetired

# ---------------------------------------------------------------------------
# Reading a managed string
# ---------------------------------------------------------------------------

proc readManagedString(s: Il2CppPtr; cap: int): string =
  ## `System.String` -> a Nim string, with the header and the character run
  ## guarded SEPARATELY. Returns "" for anything it could not read, which
  ## callers must treat as "no answer", never as "empty".
  result = ""
  if cast[uint](s) == 0'u:
    return
  if lamReadable(s, int32(StrCharOff)) == 0'i32:
    return
  var n: int32 = 0
  if lamReadI32(at(s, StrLenOff), addr n) == 0'i32:
    return
  if n <= 0'i32 or int(n) > cap:
    return
  let chars = at(s, StrCharOff)
  for i in 0 ..< int(n):
    let c = lamStrChar(chars, int32(i))
    if c < 0:
      return ""
    # The ids and mesh names we deal with are ASCII. A unit outside that range
    # means we are not looking at what we think we are.
    if c < 32 or c > 126:
      return ""
    result.add char(c)

proc isMongoId(s: string): bool =
  ## Exactly 24 lowercase-or-digit hex characters. This is what makes the
  ## inline-struct offset inference in the header falsifiable.
  if s.len != TplIdChars:
    return false
  for ch in s:
    if not ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F')):
      return false
  result = true

proc meshFor(tpl: string): (string, bool) =
  ## (mesh name, was it a real table hit). The bool matters: a fallback is a
  ## different outcome from a hit and the counters keep them apart, because
  ## "every mag animated as a stanag" is a bug that a single `spawned` counter
  ## would hide.
  var i = 0
  while i < MeshTable.len and i < MaxMeshEntries:
    if MeshTable[i].tpl == tpl:
      return (MeshTable[i].mesh, true)
    inc i
  result = (FallbackMesh, false)

# ---------------------------------------------------------------------------
# Target verification
# ---------------------------------------------------------------------------

proc bytesHex(b: array[16, uint8]): string =
  const digits = "0123456789ABCDEF"
  result = ""
  for i in 0 ..< 16:
    result.add digits[int(b[i] shr 4)]
    result.add digits[int(b[i] and 0x0F'u8)]

proc rvaHex(v: uint32): string =
  const digits = "0123456789ABCDEF"
  var x = v
  result = ""
  if x == 0'u32:
    return "0"
  while x > 0'u32:
    result = $digits[int(x and 0xF'u32)] & result
    x = x shr 4

proc verifyTarget(rva: uint32; label: string; expect: array[16, uint8]): string =
  ## Resolve the RVA against the LIVE module base and byte-compare its prologue
  ## here, before asking the host to patch it. The host re-verifies the same
  ## bytes against its own STARTUP SNAPSHOT, which is the authoritative compare
  ## — this one only stops the mod ever handing `hookTyped` an address it has
  ## not itself looked at.
  ##
  ## One caveat stated rather than hidden: this reads LIVE memory, so if
  ## another feature ever detours these RVAs first, this compare reads a
  ## trampoline and refuses a correct RVA. That would be a hook-ORDER problem,
  ## not a bad address, and the message below says so.
  let fn = lamRva(rva)
  if cast[uint](fn) == 0'u:
    return "GameAssembly.dll is not mapped (GetModuleHandleA returned NULL), " &
           "so there is no base to add 0x" & rvaHex(rva) & " to"
  var buf: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  if lamReadMem(fn, cast[Il2CppPtr](addr buf[0]), 16'i32) == 0'i32:
    return "the 16 bytes at GameAssembly+0x" & rvaHex(rva) &
           " are not committed and readable"
  # The universal empty-body stub. A method that resolves to `C2 00 00` is
  # NOT its own code -- it is the bare `ret 0` shared by 6,438 methods on this
  # build, and it passes any signature check you care to write.
  if buf[0] == 0xC2'u8 and buf[1] == 0x00'u8 and buf[2] == 0x00'u8:
    return "GameAssembly+0x" & rvaHex(rva) & " is `C2 00 00` -- this build's " &
           "UNIVERSAL EMPTY-BODY STUB (shared by 6,438 methods), not " &
           label & "'s own code. Refusing."
  for i in 0 ..< 16:
    if buf[i] != expect[i]:
      return "prologue MISMATCH at GameAssembly+0x" & rvaHex(rva) &
             " -- refusing. got [" & bytesHex(buf) & "] expected [" &
             bytesHex(expect) & "]. Either this is a different game build, or " &
             "something detoured " & label & " before this ran and these are " &
             "its trampoline bytes (a hook-ORDER problem, not a bad RVA)."
  result = ""

# ---------------------------------------------------------------------------
# The EasyAssets latch
# ---------------------------------------------------------------------------

proc onFactoryCtor(frame: PatchFrame): TypedResult =
  ## Prefix on `EFT.ObjectsFactory::.ctor(IEasyAssets, ItemTemplates,
  ## IRaidCounter)`. Reads two register values and stores them. It calls
  ## nothing, dereferences nothing and writes nothing into the game, so it is
  ## safe to leave installed on every rung above `off`.
  ##
  ## It always returns `frameContinue()`: this hook never suppresses the
  ## constructor.
  result = frameContinue()
  if gRetired:
    return
  let self = selfPointer(frame)
  var ok = false
  let ea = argPointer(frame, 0, ok)
  if not ok or self == 0'u64 or ea == 0'u64:
    return
  gFactory    = cast[Il2CppPtr](self)
  gEasyAssets = cast[Il2CppPtr](ea)
  if not gLatched:
    gLatched = true
    success "loadammoanim  latched IEasyAssets from ObjectsFactory::.ctor " &
            "@0x938430 (factory and easyAssets both non-null). This is the " &
            "holder problem solved by taking the pointer from a place it is " &
            "known live, rather than from an offset that could read null."

# ---------------------------------------------------------------------------
# Reading the magazine out of a live LoadMagazineProcess
# ---------------------------------------------------------------------------

proc readMagTemplate(self: Il2CppPtr; tpl: var string; speed: var float): bool =
  ## `this -> _magazine -> Template -> _id._stringID`. FOUR hops, four checks.
  ## Returns false, having counted why, for any hop that would not read.
  tpl = ""
  speed = 1.0

  if lamReadable(self, int32(LmpSpeedOff + 4'u)) == 0'i32:
    inc gUnreadable
    discard fault()
    return false

  var sp: float32 = 0.0
  if lamReadF32(at(self, LmpSpeedOff), addr sp) != 0'i32:
    # A per-round time of 0 or a wild one is not usable as a divisor.
    if float(sp) > 0.0 and float(sp) < 60.0:
      speed = float(sp)

  let mag = lamReadPtr(at(self, LmpMagazineOff))
  if cast[uint](mag) == 0'u:
    inc gUnreadable
    return false
  if lamReadable(mag, int32(ItemTemplateOff + 8'u)) == 0'i32:
    inc gUnreadable
    discard fault()
    return false

  let tmpl = lamReadPtr(at(mag, ItemTemplateOff))
  if cast[uint](tmpl) == 0'u:
    inc gUnreadable
    return false
  if lamReadable(tmpl, int32(TplIdStringOff + 8'u)) == 0'i32:
    inc gUnreadable
    discard fault()
    return false

  let s = readManagedString(lamReadPtr(at(tmpl, TplIdStringOff)), 64)
  if not isMongoId(s):
    # THE CHECK THAT CAN FAIL. If the inline-struct offset inference is wrong
    # this is where it shows up, as a refusal naming itself -- not as a
    # plausible-looking wrong template id.
    inc gTplRefused
    return false

  tpl = s
  inc gTplRead
  result = true

# ---------------------------------------------------------------------------
# Spawning and driving the bundle prefab
# ---------------------------------------------------------------------------

proc instanceIsLive(inst: Il2CppPtr): bool =
  ## UNITY FAKE NULL. A destroyed UnityEngine.Object stays perfectly readable
  ## with its native `m_CachedPtr` zeroed, and only dies on the next internal
  ## call -- so readability is NOT liveness and a `!= nil` test is not enough.
  ## `m_CachedPtr` sits immediately after the managed header at +0x10.
  if cast[uint](inst) == 0'u:
    return false
  if lamReadable(inst, 0x18'i32) == 0'i32:
    return false
  let cached = lamReadPtr(at(inst, 0x10'u))
  if cast[uint](cached) == 0'u:
    inc gFakeNull
    return false
  result = true

proc spawnPrefab(): bool =
  ## `ObjectsFactory::InstantiateWithoutPool(IEasyAssets, ResourceKey)` @0x93AB40,
  ## the one static call that turns a bundle resource key into a live
  ## GameObject through the game's own EasyAssets pipeline. UNIQUE, real body.
  ##
  ## Refuses LOUDLY rather than silently doing nothing: a feature that declines
  ## without saying so is the worst outcome this project produces.
  if gRetired:
    return false
  if not gLatched:
    inc gSpawnRefused
    warn "loadammoanim  spawn REFUSED: no IEasyAssets has been latched yet. " &
         "ObjectsFactory::.ctor @0x938430 has not fired this session, so " &
         "there is nothing to hand InstantiateWithoutPool. This is a refusal, " &
         "not a zero result."
    return false
  if gHijackKey.len == 0:
    inc gSpawnRefused
    warn "loadammoanim  spawn REFUSED: hijackKey is empty. We cannot ADD a " &
         "bundle key on this build, so the bundle must ride an existing " &
         "vanilla key redirected by mods/textures. Set hijackKey and put the " &
         "bundle in the textures bundleRoot under that exact name."
    return false

  let o = verify(tInstantiate)
  if o.kind != coOk:
    inc gSpawnRefused
    warn "loadammoanim  spawn REFUSED: " & o.why
    return false

  var a = callArgs()
  addPtr(a, gEasyAssets)
  # The ResourceKey for our hijacked bundle. Allocated once per session, not
  # per frame.
  let key = newString(gRt, gHijackKey)
  if cast[uint](key) == 0'u:
    inc gSpawnRefused
    warn "loadammoanim  spawn REFUSED: il2cpp_string_new returned NULL for " &
         "the resource key. Nothing was called."
    return false
  addPtr(a, key)
  addPtr(a, cast[Il2CppPtr](0))   ## the trailing MethodInfo*: NULL is fine
                                  ## here -- this is not a shared generic.

  let r = callPtr(tInstantiate, a)
  if r.kind != coOk:
    inc gSpawnRefused
    if r.kind == coFaulted:
      discard fault()
    warn "loadammoanim  InstantiateWithoutPool did not return an object: " & r.why
    return false

  let inst = asPtr(r)
  if not instanceIsLive(inst):
    inc gSpawnRefused
    warn "loadammoanim  InstantiateWithoutPool returned an object whose " &
         "m_CachedPtr is zero (Unity fake null) -- treating it as NOT spawned. " &
         "Readability is not liveness."
    return false

  gInstance = inst
  inc gSpawned
  result = true

proc animPlay(state: string; layer: int; normalized: float): bool =
  ## `Animator::Play(string)` @0x524A680 -- UNIQUE, real body.
  if gRetired or not instanceIsLive(gInstance):
    return false
  let o = verify(tAnimPlay)
  if o.kind != coOk:
    warn "loadammoanim  Animator::Play refused: " & o.why
    return false
  let s = newString(gRt, state)
  if cast[uint](s) == 0'u:
    return false
  var a = callArgs()
  addPtr(a, gInstance)
  addPtr(a, s)
  addPtr(a, cast[Il2CppPtr](0))
  let r = callVoid(tAnimPlay, a)
  if r.kind == coFaulted:
    discard fault()
  result = r.kind == coOk

proc animUpdate(dt: float): bool =
  ## `Animator::Update(float)` @0x524B000 -- UNIQUE, real body. Upstream calls
  ## `Update(0f)` straight after `Play` to force the graph to actually enter
  ## the state rather than wait a frame.
  if gRetired or not instanceIsLive(gInstance):
    return false
  if verify(tAnimUpdate).kind != coOk:
    return false
  var a = callArgs()
  addPtr(a, gInstance)
  addFloat(a, dt)
  addPtr(a, cast[Il2CppPtr](0))
  let r = callVoid(tAnimUpdate, a)
  if r.kind == coFaulted:
    discard fault()
  result = r.kind == coOk

proc animSetBool(name: string; v: bool): bool =
  ## `Animator::SetBool(string, bool)` @0x52495C0.
  ##
  ## THIS RVA IS SHARED BY 2 OWNERS. That is fine here and only here: we CALL
  ## it, which is correct code for the receiver we pass. It is never detoured —
  ## detouring a shared RVA is the unbounded-blast-radius case.
  if gRetired or not instanceIsLive(gInstance):
    return false
  if verify(tAnimSetBool).kind != coOk:
    return false
  let s = newString(gRt, name)
  if cast[uint](s) == 0'u:
    return false
  var a = callArgs()
  addPtr(a, gInstance)
  addPtr(a, s)
  addBool(a, v)
  addPtr(a, cast[Il2CppPtr](0))
  let r = callVoid(tAnimSetBool, a)
  if r.kind == coFaulted:
    discard fault()
  result = r.kind == coOk

proc playDraw(): bool =
  ## Upstream's `LoadAmmoBundleController.vmethod_0` / `PlayDraw`, verbatim in
  ## effect: jump to the draw state on layer 1, force the graph to enter it,
  ## then latch `Active` so the loop keeps running. The state names and the
  ## layer are the bundle's own -- they must match the authored Animator graph
  ## exactly, and they come from upstream's controller source, not from a guess.
  result = animPlay("OUT TO USE S", 1, 0.0)
  if result:
    discard animUpdate(0.0)
    discard animSetBool("Active", true)

proc playPutAway(): bool =
  ## Upstream's `PlayPutAway`. `Active` goes false first, then the explicit
  ## `Play` covers the case where the graph has no transition out of the
  ## put-away state once entered.
  discard animSetBool("Active", false)
  result = animPlay("USE TO OUT S", 1, 0.0)

# ---------------------------------------------------------------------------
# The trigger
# ---------------------------------------------------------------------------

proc onLoadMagazineProcCtor(frame: PatchFrame): TypedResult =
  ## THE BROAD PROBE. Prefix on `LoadMagazineProcess::.ctor` @0x768D40.
  ##
  ## It counts, and on the first firing it says so. It touches NOTHING: no
  ## pointer is dereferenced, no method is called, no memory is written, on any
  ## rung and regardless of `mode`. That is deliberate -- a probe whose job is
  ## to prove the plumbing must not be able to be the thing that breaks.
  ##
  ## No `aowl_p_p_seh` of its own: the host's guard already wraps this body and
  ## it is NOT re-entrant.
  result = frameContinue()
  inc gCtorFires
  if gCtorFires == 1'i64:
    success "loadammoanim  BROAD PROBE FIRED: LoadMagazineProcess::.ctor " &
            "@0x768D40 constructed. The TYPE is on the player's magazine-load " &
            "path. If `Start` never follows this, the type is right and the " &
            "hooked entry point is wrong."

proc onLoadMagazineStart(frame: PatchFrame): TypedResult =
  ## Fires BEFORE `LoadMagazineProcess::Start` runs. This is the real
  ## equivalent of upstream's `Class1204.Start` prefix, re-identified by
  ## signature and field shape rather than by name.
  ##
  ## It ALWAYS returns `frameContinue()`. The vanilla load is never suppressed,
  ## never re-timed and never altered: on every rung, magazine loading itself
  ## behaves exactly as it does with this mod off. We only add something
  ## visible alongside it.
  ##
  ## This adds no `aowl_p_p_seh` of its own -- the host's guard is already
  ## around this body and it is NOT re-entrant, so a nested one would DISARM
  ## the outer rather than add protection.
  result = frameContinue()
  inc gStartFires
  # THE FIRST FIRING ANNOUNCES ITSELF, UNCONDITIONALLY, ON EVERY RUNG
  # INCLUDING `probe`. Before this line existed, `mode=probe` incremented a
  # counter that only the (dead) HTTP stats route could read, so a real
  # magazine load produced total silence -- indistinguishable from the hook
  # never firing at all. Silence is never the output of a working feature.
  if not gFirstLogged:
    gFirstLogged = true
    success "loadammoanim  FIRST FIRING: LoadMagazineProcess::Start @0x768F50 " &
            "entered (ctorFires=" & $gCtorFires & " before it). The trigger " &
            "IS on the path the player took. mode=" & modeName(gMode) &
            (if gMode <= ModeProbe:
               " -- probe counts only, nothing is read, spawned or animated."
             else: "")
  if gRetired or gMode <= ModeProbe:
    return

  let self = selfPointer(frame)
  if self == 0'u64:
    inc gUnreadable
    discard fault()
    return

  var tpl = ""
  var speed = 1.0
  if not readMagTemplate(cast[Il2CppPtr](self), tpl, speed):
    return

  let (mesh, hit) = meshFor(tpl)
  if hit: inc gMeshHits else: inc gMeshFallback

  gInSession    = true
  gSessionTpl   = tpl
  gSessionMesh  = mesh
  gSessionSpeed = speed
  inc gSessions

  if gLogSessions and gSessionsLogged < MaxSessionsLogged:
    inc gSessionsLogged
    info "loadammoanim  session " & $gSessions & ": mag tpl " & tpl &
         " -> mesh " & mesh & (if hit: " (table hit)" else: " (FALLBACK)") &
         ", " & $speed & "s per round" &
         (if gSessionsLogged == MaxSessionsLogged:
            " [further sessions counted, not logged]" else: "")

  if gMode < ModeSpawn:
    return
  if not spawnPrefab():
    return
  if gMode < ModeAnimate:
    return
  if playDraw():
    inc gAnimDriven
    gSessionStartedMs = nowMs()

proc endSession(playAway: bool) =
  ## Terminal teardown. The put-away clip plays with the mesh still visible;
  ## the instance is released once it has had its cap's worth of time. This is
  ## the only place `gInstance` is cleared, so a session can never leak into
  ## the next one.
  if not gInSession:
    return
  gInSession = false
  if playAway and gMode >= ModeAnimate:
    discard playPutAway()
  gInstance = cast[Il2CppPtr](0)
  inc gTeardowns

proc onLoadMagazineEnd(frame: PatchFrame): TypedResult =
  ## Prefix on `LoadMagazineProcess::RaiseLoadEventArgs(CommandStatus)`
  ## @0x769260 — UNIQUE, real body, prologue verified. This is the session's
  ## own terminal signal, raised however the load ends (finished, cancelled or
  ## aborted), which is why it is hooked in preference to inferring the end
  ## from a magazine count that upstream itself found unreliable.
  ##
  ## Always returns `frameContinue()`: the event is never suppressed.
  result = frameContinue()
  if gRetired or gMode <= ModeProbe:
    return
  endSession(true)

# ---------------------------------------------------------------------------
# Configuration and arming
# ---------------------------------------------------------------------------

proc modeFromText(s: string): int =
  case s
  of "probe":   ModeProbe
  of "read":    ModeRead
  of "spawn":   ModeSpawn
  of "animate": ModeAnimate
  else:         ModeOff

proc modeName(m: int): string =
  case m
  of ModeProbe:   "probe (count Start firings only)"
  of ModeRead:    "read (resolve mag tpl -> mesh; nothing called or written)"
  of ModeSpawn:   "spawn (instantiate the bundle prefab)"
  of ModeAnimate: "animate (drive the bundle Animator)"
  else:           "off"

proc loadConfig() =
  gEnabled     = setting("enabled").asBool(false)
  gMode        = modeFromText(setting("mode").asText("off"))
  gBundlePath  = setting("bundlePath").asText("")
  gHijackKey   = setting("hijackKey").asText("")
  gDrawClipSec = setting("drawClipSeconds").asFloat(0.867)
  gPutAwayMax  = setting("putAwayMaxWaitSeconds").asFloat(1.5)
  gMaxFaults   = setting("maxFaults").asInt(8)
  gArmDelayMs  = int64(setting("armDelayMs").asInt(12000))
  gLogSessions = setting("logSessions").asBool(true)
  if not gEnabled:
    gMode = ModeOff

proc readyToArm(): bool =
  if gMode == ModeOff:
    return false
  if nowMs() - gLoadedAtMs < gArmDelayMs:
    return false
  if not gRt.loaded:
    gRt = openIl2Cpp()
  result = verifyTarget(TgtStartRva, "LoadMagazineProcess::Start",
                        StartProlog).len == 0

proc maybeArm(): bool =
  ## Installs the two verified prefixes exactly once, and only when it is safe
  ## to. If verification refuses it does NOT retry: one honest refusal, not a
  ## per-tick log storm.
  if gArmed or gArmTried:
    return false
  if not readyToArm():
    return false
  gArmTried = true

  let whyStart = verifyTarget(TgtStartRva, "LoadMagazineProcess::Start",
                              StartProlog)
  if whyStart.len > 0:
    warn "loadammoanim  NOT hooking LoadMagazineProcess::Start: " & whyStart
    return false
  let whyCtor = verifyTarget(TgtFactoryCtorRva, "EFT.ObjectsFactory::.ctor",
                             FactoryCtorProlog)
  if whyCtor.len > 0:
    warn "loadammoanim  NOT hooking EFT.ObjectsFactory::.ctor: " & whyCtor &
         " -- without this latch nothing can be spawned, so the feature will " &
         "run at most in `read`."

  # The call targets. Declared with their owner counts so the log line carries
  # sharedness: `Animator::SetBool` is SHARED by 2 owners and is CALLED, never
  # detoured.
  tInstantiate = rvaTarget("EFT.ObjectsFactory::InstantiateWithoutPool",
                           RvaInstantiateNoPool, SigInstantiateNoPool, 1)
  tAnimPlay    = rvaTarget("UnityEngine.Animator::Play",
                           RvaAnimPlay, SigAnimPlay, 1)
  tAnimSetBool = rvaTarget("UnityEngine.Animator::SetBool",
                           RvaAnimSetBool, SigAnimSetBool, 2)
  tAnimUpdate  = rvaTarget("UnityEngine.Animator::Update",
                           RvaAnimUpdate, SigAnimUpdate, 1)

  if gMode >= ModeSpawn and not gRt.has(eStringNew):
    warn "loadammoanim  the runtime has no il2cpp_string_new, so no resource " &
         "key or animator state name can be built -- running at most in " &
         "`read`. This is a refusal that says so, not a silent degradation."

  let st = hookTyped(TgtStart, onLoadMagazineStart)
  if st != Ok:
    warn "loadammoanim  hookTyped refused LoadMagazineProcess::Start: " &
         lastError()
    return false
  if whyCtor.len == 0:
    let st2 = hookTyped(TgtFactoryCtor, onFactoryCtor)
    if st2 != Ok:
      warn "loadammoanim  hookTyped refused EFT.ObjectsFactory::.ctor: " &
           lastError() & " -- the EasyAssets latch is unavailable."

  # The broad probe. Verified and installed exactly like the others; a refusal
  # is stated, never swallowed, because a MISSING probe and a probe that NEVER
  # FIRED look identical in the heartbeat unless the heartbeat knows which.
  let whyPCtor = verifyTarget(TgtProcCtorRva, "LoadMagazineProcess::.ctor",
                              ProcCtorProlog)
  if whyPCtor.len > 0:
    warn "loadammoanim  NOT hooking the broad probe LoadMagazineProcess::.ctor: " &
         whyPCtor & " -- the heartbeat will report ctorProbe=NOT INSTALLED, " &
         "so a zero there must NOT be read as 'never constructed'."
  else:
    let st4 = hookTyped(TgtProcCtor, onLoadMagazineProcCtor)
    if st4 == Ok:
      gCtorHooked = true
    else:
      warn "loadammoanim  hookTyped refused the broad probe " &
           "LoadMagazineProcess::.ctor: " & lastError()

  let whyEnd = verifyTarget(TgtEndRva, "LoadMagazineProcess::RaiseLoadEventArgs",
                            EndProlog)
  if whyEnd.len > 0:
    warn "loadammoanim  NOT hooking LoadMagazineProcess::RaiseLoadEventArgs: " &
         whyEnd & " -- sessions will close on the safety cap instead, which " &
         "will show up as a non-zero `timedOut`."
  else:
    let st3 = hookTyped(TgtEnd, onLoadMagazineEnd)
    if st3 != Ok:
      warn "loadammoanim  hookTyped refused " &
           "LoadMagazineProcess::RaiseLoadEventArgs: " & lastError()

  gArmed = true
  success "loadammoanim  ARMED in mode " & modeName(gMode) &
          "; trigger LoadMagazineProcess::Start @0x768F50 (UNIQUE, prologue " &
          "verified), latch ObjectsFactory::.ctor @0x938430. Vanilla magazine " &
          "loading is never suppressed on any rung."
  result = true

proc loadAmmoAnimStats*(): string =
  ## The acceptance instrument. The §9b negative this exists to make
  ## falsifiable is BEHAVIOURAL: with the flag on, a magazine load must take
  ## measurable time and pass through intermediate states. An instant transfer
  ## must read FAIL, not PASS.
  ##
  ## `sessions == 0` is INCONCLUSIVE, never PASS -- it means no magazine was
  ## ever loaded during the run, which is "I could not look", not "it worked".
  ## The counters are kept separate precisely so that "never exercised",
  ## "exercised and refused" and "exercised and worked" cannot be confused.
  result = "{\"kind\":\"loadAmmoAnim\"" &
           ",\"enabled\":" & (if gEnabled: "true" else: "false") &
           ",\"mode\":" & $gMode &
           ",\"armed\":" & (if gArmed: "true" else: "false") &
           ",\"retired\":" & (if gRetired: "true" else: "false") &
           ",\"latched\":" & (if gLatched: "true" else: "false") &
           ",\"hijackKey\":\"" & gHijackKey & "\"" &
           ",\"startFires\":" & $gStartFires &
           ",\"ctorProbeHooked\":" & (if gCtorHooked: "true" else: "false") &
           ",\"ctorFires\":" & $gCtorFires &
           ",\"sessions\":" & $gSessions &
           ",\"tplRead\":" & $gTplRead &
           ",\"tplRefused\":" & $gTplRefused &
           ",\"meshHits\":" & $gMeshHits &
           ",\"meshFallback\":" & $gMeshFallback &
           ",\"spawned\":" & $gSpawned &
           ",\"spawnRefused\":" & $gSpawnRefused &
           ",\"animDriven\":" & $gAnimDriven &
           ",\"teardowns\":" & $gTeardowns &
           ",\"timedOut\":" & $gTimedOut &
           ",\"fakeNull\":" & $gFakeNull &
           ",\"unreadable\":" & $gUnreadable &
           ",\"faults\":" & $gFaults &
           ",\"lastTpl\":\"" & gSessionTpl & "\"" &
           ",\"lastMesh\":\"" & gSessionMesh & "\"}"

proc reportText(): string =
  ## The heartbeat line. Its ONE job is to make the following three states
  ## impossible to confuse, in words, without the reader having to know what a
  ## zero means:
  ##
  ##   NOT ARMED          -- no hook is installed; a zero counter says nothing.
  ##   ARMED, NEVER FIRED -- the hooks ARE installed and have not been entered.
  ##   ARMED, FIRED n     -- entered n times, and here is what happened next.
  ##
  ## Under the old code all three printed nothing at all, and the counters were
  ## reachable only through `serve("/aowlspt/loadammoanim/stats")` -- a route
  ## the GAME PROCESS CANNOT SERVE, because the client host runs no HTTP
  ## server. The numbers existed and were unreadable by construction.
  if not gArmed:
    return "loadammoanim  NOT ARMED" &
           (if not gEnabled: " (enabled=false)"
            elif gMode == ModeOff: " (mode=off)"
            elif not gArmTried: " (waiting out armDelayMs)"
            else: " (arming was TRIED and REFUSED -- see the warn above)") &
           ". No hook is installed, so every counter below would be zero for " &
           "that reason alone. This is NOT evidence about the trigger."

  let probeState =
    if not gCtorHooked: "NOT INSTALLED"
    elif gCtorFires == 0'i64: "installed, never fired"
    else: "fired " & $gCtorFires

  if gStartFires == 0'i64 and gCtorFires == 0'i64:
    return "loadammoanim  ARMED but NEVER FIRED. mode=" & modeName(gMode) &
           ", latched=" & (if gLatched: "yes" else: "no") &
           ". LoadMagazineProcess::Start @0x768F50 has been entered ZERO " &
           "times and the broad probe LoadMagazineProcess::.ctor @0x768D40 is " &
           probeState & ". Both are installed and verified, so this is " &
           "'installed and never entered', NOT 'not installed'. If a magazine " &
           "was loaded during this run, LoadMagazineProcess is NOT the type " &
           "that in-raid load goes through and the shape-based identification " &
           "is wrong. If no magazine was loaded, this line is INCONCLUSIVE."

  if gStartFires == 0'i64:
    return "loadammoanim  ARMED; broad probe " & probeState & " but " &
           "LoadMagazineProcess::Start @0x768F50 fired ZERO times. The TYPE " &
           "is right and the hooked ENTRY POINT is wrong -- the process is " &
           "constructed and Start is not the method that runs. Look at " &
           "LoadProcess @0x7693E0 / PlaySound @0x7695E0 instead."

  result = "loadammoanim  ARMED and FIRING. mode=" & modeName(gMode) &
           " startFires=" & $gStartFires &
           " ctorProbe=" & probeState &
           " sessions=" & $gSessions &
           " tplRead=" & $gTplRead & " tplRefused=" & $gTplRefused &
           " meshHits=" & $gMeshHits & " meshFallback=" & $gMeshFallback &
           " spawned=" & $gSpawned & " spawnRefused=" & $gSpawnRefused &
           " animDriven=" & $gAnimDriven & " teardowns=" & $gTeardowns &
           " timedOut=" & $gTimedOut & " fakeNull=" & $gFakeNull &
           " unreadable=" & $gUnreadable & " faults=" & $gFaults &
           " retired=" & (if gRetired: "YES" else: "no") &
           " lastTpl=" & (if gSessionTpl.len == 0: "-" else: gSessionTpl) &
           " lastMesh=" & (if gSessionMesh.len == 0: "-" else: gSessionMesh)
  if gMode <= ModeProbe:
    result.add "  [mode=probe: Start is counted and NOTHING further is read, " &
               "spawned or animated -- the zeros after startFires are the " &
               "MODE, not a failure]"

proc report(force: bool) =
  ## Prints on CHANGE, and otherwise on a slow heartbeat, so a stuck state
  ## cannot scroll away and a healthy one cannot spam. `force` is used for the
  ## first report after arming.
  let text = reportText()
  let now = nowMs()
  if force or text != gLastReport or (now - gLastReportMs) >= ReportEveryMs:
    gLastReport   = text
    gLastReportMs = now
    info text

proc onStats(url, body, session: string): string {.used.} =
  loadAmmoAnimStats()

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

proc schema(): seq[Setting] =
  @[
    boolSetting("enabled", "Enable loading animations", false,
                category = "Ammo loading",
                description = "Port of Manimal's Ammo Loading Animations (MIT). " &
                  "Plays a first-person animation of hands thumbing rounds into " &
                  "the magazine while it loads. DEFAULT OFF: this detours the " &
                  "live magazine-loading flow during gameplay. Vanilla loading " &
                  "is never suppressed -- the animation is added alongside it."),
    enumSetting("mode", "Escalation rung", "off",
                @["off", "probe", "read", "spawn", "animate"],
                category = "Ammo loading",
                description = "Move up ONE rung at a time. probe: count " &
                  "detections only. read: also resolve which magazine is being " &
                  "loaded (nothing called or written). spawn: also instantiate " &
                  "the animation prefab. animate: also play it -- only this rung " &
                  "is visible. Each rung is strictly additive over the one below."),
    stringSetting("bundlePath", "Bundle file", "",
                category = "Ammo loading",
                description = "Absolute path to stanags_container.bundle, the " &
                  "upstream mod's shipped asset. A copy ships in this mod's " &
                  "data/ directory and is used when this is empty."),
    stringSetting("hijackKey", "Bundle key to ride", "",
                category = "Ammo loading",
                description = "This build cannot ADD a bundle key, so our " &
                  "bundle must replace an existing vanilla one, redirected by " &
                  "mods/textures. That key's real asset is unavailable while " &
                  "this is on -- pick one nothing in a raid loads."),
    floatSetting("drawClipSeconds", "Draw clip length", 0.867,
                 lo = 0.1, hi = 3.0, step = 0.001, category = "Timing",
                 description = "Length of the bundle's draw clip, used to " &
                   "stretch the first-round wait so the draw finishes before a " &
                   "round seats. Upstream's value, not re-measured here."),
    floatSetting("putAwayMaxWaitSeconds", "Put-away wait cap", 1.5,
                 lo = 0.1, hi = 5.0, step = 0.1, category = "Timing",
                 description = "Ceiling on waiting for the put-away clip before " &
                   "tearing down anyway. A cap, not an expectation."),
    intSetting("maxFaults", "Self-disable after N faults", 8,
               lo = 1, hi = 64, category = "Safety",
               description = "After this many unreadable hops or faulted calls " &
                 "the feature retires for the session and stops touching the " &
                 "game, while continuing to count."),
    intSetting("armDelayMs", "Arm delay (ms)", 12000,
               lo = 0, hi = 120000, category = "Safety",
               description = "How long after load before hooks are installed, " &
                 "deferring past the boot asset storm."),
    boolSetting("logSessions", "Log each loading session", true,
                category = "Safety",
                description = "One capped line per session naming the magazine " &
                  "and the mesh chosen. Turn off once settled.")]

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  loadConfig()
  declareSettings(schema())
  gLoadedAtMs = nowMs()
  # NO `serve("/aowlspt/loadammoanim/stats", onStats)` HERE, DELIBERATELY.
  # This mod runs CLIENT-SIDE, inside the game process, and the game process
  # runs no HTTP server: `serve` from a client mod registers a route into
  # nothing. The route existed, returned correct JSON, and was unreachable by
  # construction -- which is why a real magazine load produced zero readable
  # evidence. The counters now go to the HOST LOG via `report`, which is the
  # only channel a client mod actually has. `loadAmmoAnimStats` is kept because
  # it is the machine-readable form the BACKEND side can serve if this mod ever
  # grows one.
  discard

  if not gEnabled:
    info "loadammoanim  disabled (enabled=false). No hook is installed and " &
         "magazine loading is exactly vanilla."
    return Ok
  if gMode == ModeOff:
    info "loadammoanim  enabled but mode=off, so nothing is installed. Set " &
         "mode to `probe` and escalate one rung at a time."
    return Ok
  if gBundlePath.len == 0:
    info "loadammoanim  bundlePath is empty; the copy shipped in this mod's " &
         "data/ directory is the one that will be used."
  info "loadammoanim  will arm in " & $gArmDelayMs & "ms, mode " & modeName(gMode)
  Ok

proc onUpdate(elapsedMs: int64): Status =
  let justArmed = maybeArm()
  # THE REPORT. This is the whole reason a magazine load is no longer silent.
  # It runs only once the mod is enabled, so a disabled mod stays quiet, and it
  # is throttled to ReportEveryMs unless the text CHANGED.
  if gEnabled:
    report(justArmed)
  # The safety cap. If the terminal hook never fires, a session would otherwise
  # hold a spawned instance forever. Bounded, cheap, and it COUNTS ITSELF: a
  # non-zero `timedOut` in the stats is evidence that the end signal is not
  # arriving, which is exactly the kind of silent wrongness that a cap without
  # a counter would hide.
  if gInSession and gSessionStartedMs > 0:
    let ageMs = nowMs() - gSessionStartedMs
    # Generous: a full 60-round drum at the slowest skill level, plus the
    # put-away cap. This is a backstop, not the normal path.
    if ageMs > 120000:
      inc gTimedOut
      warn "loadammoanim  session closed by the SAFETY CAP after " & $ageMs &
           "ms, not by LoadMagazineProcess::RaiseLoadEventArgs. The terminal " &
           "signal did not arrive -- see timedOut in loadAmmoAnimStats."
      endSession(false)
  Ok

proc onUnload(): Status =
  endSession(false)
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
