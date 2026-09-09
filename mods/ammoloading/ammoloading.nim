## aowl.ammoloading — "Ammo Loading". Everything about putting rounds into a
## magazine and taking them out again.
##
##     aowl build-mod mods/ammoloading
##
## TWO FEATURES, ONE OF WHICH LIVES SOMEWHERE ELSE ON PURPOSE:
##
## 1. **the ANIMATION** — first-person hands thumbing rounds in. That is all
##    the code in this file. Status, honestly: ARMED but NEVER FIRED; see
##    README.md.
## 2. **the SPEED** — how long a load or unload takes. This is NOT implemented
##    here and must not be. It is a server database value,
##    `globals.config.BaseLoadTime` (0.85), `globals.config.BaseUnloadTime`
##    (0.3) and `globals.config.LoadTimeSpeedProgress` (1), and all three are
##    ALREADY among the 770 rows `mods/tarkov/emu/globaltunedata.nim` exposes
##    (`g_BaseLoadTime`, `g_BaseUnloadTime`, `g_LoadTimeSpeedProgress`, category
##    "Globals"). Declaring a control for them here would mean two settings
##    writing one value, which is the exact shape that produces "I changed it
##    and nothing happened". This mod LINKS to them; it does not own them.
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
  ModGuid    = "aowl.ammoloading"
  ModName    = "Ammo Loading"
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
    warn "ammoloading  RETIRED after " & $gMaxFaults & " faults " &
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
    success "ammoloading  latched IEasyAssets from ObjectsFactory::.ctor " &
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
    warn "ammoloading  spawn REFUSED: no IEasyAssets has been latched yet. " &
         "ObjectsFactory::.ctor @0x938430 has not fired this session, so " &
         "there is nothing to hand InstantiateWithoutPool. This is a refusal, " &
         "not a zero result."
    return false
  if gHijackKey.len == 0:
    inc gSpawnRefused
    warn "ammoloading  spawn REFUSED: hijackKey is empty. We cannot ADD a " &
         "bundle key on this build, so the bundle must ride an existing " &
         "vanilla key redirected by mods/textures. Set hijackKey and put the " &
         "bundle in the textures bundleRoot under that exact name."
    return false

  let o = verify(tInstantiate)
  if o.kind != coOk:
    inc gSpawnRefused
    warn "ammoloading  spawn REFUSED: " & o.why
    return false

  var a = callArgs()
  addPtr(a, gEasyAssets)
  # The ResourceKey for our hijacked bundle. Allocated once per session, not
  # per frame.
  let key = newString(gRt, gHijackKey)
  if cast[uint](key) == 0'u:
    inc gSpawnRefused
    warn "ammoloading  spawn REFUSED: il2cpp_string_new returned NULL for " &
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
    warn "ammoloading  InstantiateWithoutPool did not return an object: " & r.why
    return false

  let inst = asPtr(r)
  if not instanceIsLive(inst):
    inc gSpawnRefused
    warn "ammoloading  InstantiateWithoutPool returned an object whose " &
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
    warn "ammoloading  Animator::Play refused: " & o.why
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
    success "ammoloading  BROAD PROBE FIRED: LoadMagazineProcess::.ctor " &
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
    success "ammoloading  FIRST FIRING: LoadMagazineProcess::Start @0x768F50 " &
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
    info "ammoloading  session " & $gSessions & ": mag tpl " & tpl &
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
# THE PROBE BANK -- read-only PREFIX drains on the MEASURED in-raid reload path
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS. The hooks above target `LoadMagazineProcess`, and across a
# full raid in which the player loaded and unloaded magazines they were entered
# ZERO times (instrument: this mod's own heartbeat in `aowlspt-host.log`).
# `docs/AMMO-LOADING-MAP.md` says why, and the reason is structural, not a bad
# RVA: MEASURED `il2cpp_resolve.py callers 0x768d40` returns exactly ONE caller
# site, `<LoadMagazine>d__51::MoveNext`, and the declaring-type walk puts all of
# it inside `EFT.Player/PlayerInventoryController`. `LoadMagazineProcess` is the
# round-by-round INVENTORY magazine-filling process. A weapon reload never
# constructs it -- it runs `FirearmController`'s reload OPERATIONS, which either
# swap a whole magazine (external mag: there is no per-round transfer at all) or
# commit an ammo delta directly (internal mag).
#
# So the identification-by-shape was wrong, and this bank is the empirical
# replacement: one prefix per MEASURED entry point, grouped into KINDS, so the
# next raid prints `fired N times` per site and names the receiver.
#
# EVERY SITE IS:
#   * MEASURED UNIQUE (owners == 1) by `il2cpp_resolve.py shared <RVA>`. Not one
#     SHARED address is bound -- notably NOT `FirearmController`'s
#     `IEventsConsumerOnAddAmmoInMag`/`AddAmmoToMag` pair @0x77FA80, which is
#     SHARED x2 and therefore ineligible however benign two owners look.
#   * in the `il2cpp` PE section, and NOT the `C2 00 00` universal empty stub.
#   * bound as a PREFIX. `CommitReloadWithAmmo` @0x7B45C0 has SIX slots
#     (this + 5); its 5th argument lives on the CALLER's stack, so a POSTFIX
#     there is a crash by construction. Prefix-only removes the question.
#   * READ-ONLY. It increments a counter and, on the FIRST firing of that site
#     only, reads the receiver's klass name. It never writes, never calls into
#     game code, and always returns `frameContinue()`, on every rung.
#
# No `aowl_p_p_seh` is opened here: the host's guard already wraps each handler
# body and it is NOT re-entrant.

const
  ## Probe kinds. The verdict in `reportText` is written in terms of these,
  ## not of individual sites, because which OPERATION a weapon uses is chosen
  ## at runtime and is not knowable offline.
  PkInput   = 0   ## the LOCAL player's reload input reached FirearmController
  PkOpStart = 1   ## a reload operation began -- the reload animation is running
  PkAnim    = 2   ## the animator was told to reload (ALSO fires for OTHER
                  ## players: 7 of the 13 measured call sites of
                  ## FirearmsAnimator::Reload(bool) are NextObservedPlayer
                  ## hands operations)
  PkAmmo    = 3   ## the magazine's ammo actually changed
  PkInv     = 4   ## an INVENTORY magazine fill/empty (in raid or out of raid)
  PkCount   = 5

  ProbeKindName: array[PkCount, string] =
    ["input", "opstart", "anim", "ammo", "inv"]

  NProbe = 19

  ## name / RVA / prologue / shape / kind, as five parallel arrays so the table
  ## is editable one column at a time and a length mismatch is a compile error.
  ProbeName: array[NProbe, string] = [
    "FirearmController::ReloadMag",
    "FirearmController::QuickReloadMag",
    "FirearmController::ReloadWithAmmo",
    "FirearmController::ReloadCylinderMagazine",
    "FirearmController::ReloadBarrels",
    "FirearmController::CheckAmmo",
    "ReloadExternalMagOperation::Start",
    "ReloadInternalMagBase::Start",
    "FirearmsAnimator::Reload_b",
    "FirearmsAnimator::Reload_iib",
    "FirearmsAnimator::LoadOneTrigger",
    "ReloadExternalMagOperation::OnMagInsertedToWeapon",
    "ReloadInternalMagOperation::CommitReloadWithAmmo",
    "ReloadInternalMagOperation::AddAmmoToMag",
    "ReloadCylinderMagOperation::AddAmmoToMag",
    "PlayerInventoryController::LoadMagazine",
    "PlayerInventoryController::UnloadMagazine",
    "ItemController::LoadMagazine",
    "ItemUiContext::LoadAmmoByType"]

  ProbeRva: array[NProbe, uint32] = [
    0x7843E0'u32, 0x784570'u32, 0x7848F0'u32, 0x7847A0'u32, 0x784AD0'u32,
    0x7840C0'u32, 0x7B08F0'u32, 0x7B3580'u32, 0x1C82E80'u32, 0x1C7E7C0'u32,
    0x1C82A90'u32, 0x7B1C70'u32, 0x7B45C0'u32, 0x7B40F0'u32, 0x7AF550'u32,
    0x766930'u32, 0x766BC0'u32, 0x10E5180'u32, 0x151DB70'u32]

  ## The 16 prologue bytes, MEASURED with `Resolver.code_bytes(rva, 16)` on
  ## GameAssembly.dll (123,891,024 bytes, 2026-08-12). Several rows are
  ## IDENTICAL: sixteen bytes of a standard register-save prologue are not an
  ## identity check, they are a "has anyone already patched this" check.
  ## Identity comes from the per-image methodPointers RVA.
  ProbeProlog: array[NProbe, string] = [
    "48895C240848896C2410488974241857",
    "48895C24084889742410574883EC3080",
    "48895C24084889742410574883EC3080",
    "48895C240848896C2410488974241857",
    "48895C240848896C2410488974241857",
    "40534883EC20803D5742930600488BD9",
    "405341574883EC588B05425C90064C8D",
    "48895C241048896C2418574883EC3049",
    "40534883EC20803D07D5430500488BD9",
    "48895C24084889742410574883EC2041",
    "48895C2408574883EC30803DEFD84305",
    "40534883EC2080797C00488BD90F85A1",
    "4053574154415541574883EC40803D5C",
    "48895C2410574883EC20803D2D439006",
    "48895C2408574883EC2033D2488BD9E8",
    "48895C240848896C2410488974241857",
    "48895C2408574881EC80000000803DBA",
    "48895C24084889742410574883EC5080",
    "48895C240848896C2410488974241857"]

  ## Frame shapes, DERIVED from the metadata signature (returnType@8 /
  ## parameterStart@16 / parameterCount@34), never inferred from the name.
  ## `i` = integer/bool/enum and `this`, `o` = managed reference, `x` = void.
  ProbeShape: array[NProbe, string] = [
    "iooo>x",   # ReloadMag(Magazine, ItemAddress, Callback)
    "ioo>x",    # QuickReloadMag(Magazine, Callback)
    "ioo>x",    # ReloadWithAmmo(AmmoPack, Callback)
    "iooi>x",   # ReloadCylinderMagazine(AmmoPack, Callback, bool)
    "iooo>x",   # ReloadBarrels(AmmoPack, ItemAddress, Callback)
    "i>i",      # CheckAmmo() -> bool
    "ioo>x",    # ReloadExternalMagOperation::Start(Result, Callback)
    "ioo>x",    # ReloadInternalMagBase::Start(AmmoPack, Callback)
    "ii>x",     # FirearmsAnimator::Reload(bool)
    "iiii>x",   # FirearmsAnimator::Reload(int, int, bool)
    "ii>x",     # FirearmsAnimator::LoadOneTrigger(bool)
    "i>x",      # OnMagInsertedToWeapon()
    "iiooo>x",  # CommitReloadWithAmmo(int, AmmoPack, Player, Magazine, Weapon)
    "i>x",      # ReloadInternalMagOperation::AddAmmoToMag()
    "i>x",      # ReloadCylinderMagOperation::AddAmmoToMag()
    "iooii>o",  # LoadMagazine(Ammo, Magazine, int, bool) -> Task<IResult>
    "ioi>o",    # UnloadMagazine(Magazine, bool) -> Task<IResult>
    "iooii>o",  # ItemController::LoadMagazine(...) -> Task<IResult>
    "iooo>o"]   # LoadAmmoByType(Magazine, string, Action) -> Task

  ProbeKind: array[NProbe, int] = [
    PkInput, PkInput, PkInput, PkInput, PkInput, PkInput,
    PkOpStart, PkOpStart,
    PkAnim, PkAnim, PkAnim,
    PkAmmo, PkAmmo, PkAmmo, PkAmmo,
    PkInv, PkInv, PkInv, PkInv]

  ## `Il2CppClass.name`. MEASURED either side (`image`@0x00 from
  ## il2cpp_class_get_image, `namespaze`@0x18 from il2cpp_class_get_namespace);
  ## 0x10 itself is INFERRED from the canonical head, exactly as
  ## abi/aowlspt_components.h documents, because il2cpp_class_get_name on this
  ## build is a TLS thread-attach wrapper and not an accessor. It is therefore
  ## never TRUSTED -- see `readKlassName`, which refuses anything that is not a
  ## NUL-terminated run of printable ASCII and prints UNREADABLE instead of a
  ## plausible wrong type name.
  KlassNameOff = 0x10'u
  KlassNameMax = 64

var
  gProbeFires:  array[NProbe, int64]
  gProbeBound:  array[NProbe, bool]
  gProbeNamed:  array[NProbe, bool]
  gProbeKlass:  array[NProbe, string]
  gProbeArmed   = false
  gProbeBoundN  = 0
  gProbeRefused = 0

proc probeInit() =
  for i in 0 ..< NProbe:
    gProbeFires[i] = 0'i64
    gProbeBound[i] = false
    gProbeNamed[i] = false
    gProbeKlass[i] = ""

proc hex16(s: string): array[16, uint8] =
  ## 32 hex characters -> 16 bytes. A malformed row yields bytes that cannot
  ## match, so `verifyTarget` refuses loudly rather than binding something
  ## unchecked.
  result = [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  if s.len < 32:
    return
  for i in 0 ..< 16:
    var v = 0
    for k in 0 ..< 2:
      let c = s[i * 2 + k]
      var d = 0
      if c >= '0' and c <= '9':
        d = int(ord(c) - ord('0'))
      elif c >= 'A' and c <= 'F':
        d = int(ord(c) - ord('A')) + 10
      elif c >= 'a' and c <= 'f':
        d = int(ord(c) - ord('a')) + 10
      v = v * 16 + d
    result[i] = uint8(v)

proc readKlassName(obj: Il2CppPtr): string =
  ## `obj -> klass -> name`, three guarded hops, capped, and FENCED.
  ##
  ## Returns "" for anything it could not read or could not validate. The
  ## caller must print UNREADABLE for "", never a guess: an INFERRED offset
  ## that is allowed to print a plausible name is precisely the
  ## confidently-wrong answer this project treats as worse than a crash.
  result = ""
  if cast[uint](obj) == 0'u:
    return
  if lamReadable(obj, 8'i32) == 0'i32:
    return
  let klass = lamReadPtr(obj)
  if cast[uint](klass) == 0'u:
    return
  if lamReadable(at(klass, KlassNameOff), 8'i32) == 0'i32:
    return
  let namep = lamReadPtr(at(klass, KlassNameOff))
  if cast[uint](namep) == 0'u:
    return
  var buf: array[KlassNameMax, uint8] = [
    0'u8, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0]
  # A C string that straddles into an uncommitted page must be TRUNCATED, not
  # faulted, so the long read is attempted first and a short one is the
  # fallback. Both are fixed-size reads behind VirtualQuery.
  var got = 0
  if lamReadMem(namep, cast[Il2CppPtr](addr buf[0]), int32(KlassNameMax)) != 0'i32:
    got = KlassNameMax
  elif lamReadMem(namep, cast[Il2CppPtr](addr buf[0]), 16'i32) != 0'i32:
    got = 16
  else:
    return
  var n = 0
  while n < got and buf[n] != 0'u8:
    inc n
  if n == 0 or n >= got:
    # No terminator inside the window: this is not a C string we looked at all
    # of, so it is not evidence. "" -> UNREADABLE.
    return
  for i in 0 ..< n:
    if buf[i] < 0x20'u8 or buf[i] > 0x7E'u8:
      return
  var s = ""
  for i in 0 ..< n:
    s.add char(buf[i])
  result = s

proc probeFire(i: int; f: PatchFrame) =
  ## The whole body of every drain. Counts FIRST -- a caught fault unwinds the
  ## guarded body silently, so a counter bumped afterwards would under-report
  ## exactly the firings that matter.
  gProbeFires[i] = gProbeFires[i] + 1'i64
  if gProbeNamed[i]:
    return
  gProbeNamed[i] = true
  if gRetired:
    gProbeKlass[i] = "RETIRED-BEFORE-CENSUS"
    return
  let self = selfPointer(f)
  let nm = readKlassName(cast[Il2CppPtr](self))
  if nm.len == 0:
    inc gUnreadable
    gProbeKlass[i] = "UNREADABLE"
  else:
    gProbeKlass[i] = nm
  success "ammoloading  PROBE FIRED [" & ProbeKindName[ProbeKind[i]] & "] " &
          ProbeName[i] & " @0x" & rvaHex(ProbeRva[i]) &
          "  receiver klass?=" & gProbeKlass[i] &
          "  (klass->name@0x10 is INFERRED and validated as printable ASCII; " &
          "UNREADABLE means it did not validate, never a guess)"

proc pFire0(f: PatchFrame): TypedResult =
  probeFire(0, f)
  frameContinue()
proc pFire1(f: PatchFrame): TypedResult =
  probeFire(1, f)
  frameContinue()
proc pFire2(f: PatchFrame): TypedResult =
  probeFire(2, f)
  frameContinue()
proc pFire3(f: PatchFrame): TypedResult =
  probeFire(3, f)
  frameContinue()
proc pFire4(f: PatchFrame): TypedResult =
  probeFire(4, f)
  frameContinue()
proc pFire5(f: PatchFrame): TypedResult =
  probeFire(5, f)
  frameContinue()
proc pFire6(f: PatchFrame): TypedResult =
  probeFire(6, f)
  frameContinue()
proc pFire7(f: PatchFrame): TypedResult =
  probeFire(7, f)
  frameContinue()
proc pFire8(f: PatchFrame): TypedResult =
  probeFire(8, f)
  frameContinue()
proc pFire9(f: PatchFrame): TypedResult =
  probeFire(9, f)
  frameContinue()
proc pFire10(f: PatchFrame): TypedResult =
  probeFire(10, f)
  frameContinue()
proc pFire11(f: PatchFrame): TypedResult =
  probeFire(11, f)
  frameContinue()
proc pFire12(f: PatchFrame): TypedResult =
  probeFire(12, f)
  frameContinue()
proc pFire13(f: PatchFrame): TypedResult =
  probeFire(13, f)
  frameContinue()
proc pFire14(f: PatchFrame): TypedResult =
  probeFire(14, f)
  frameContinue()
proc pFire15(f: PatchFrame): TypedResult =
  probeFire(15, f)
  frameContinue()
proc pFire16(f: PatchFrame): TypedResult =
  probeFire(16, f)
  frameContinue()
proc pFire17(f: PatchFrame): TypedResult =
  probeFire(17, f)
  frameContinue()
proc pFire18(f: PatchFrame): TypedResult =
  probeFire(18, f)
  frameContinue()

proc probeHandler(i: int): TypedPatchHandler =
  ## Nineteen named procs rather than a closure per site: a closure would be a
  ## per-bind allocation, and this is the shape `mods/textures/loadprobe.nim`
  ## already uses for the same reason.
  case i
  of 0:  result = pFire0
  of 1:  result = pFire1
  of 2:  result = pFire2
  of 3:  result = pFire3
  of 4:  result = pFire4
  of 5:  result = pFire5
  of 6:  result = pFire6
  of 7:  result = pFire7
  of 8:  result = pFire8
  of 9:  result = pFire9
  of 10: result = pFire10
  of 11: result = pFire11
  of 12: result = pFire12
  of 13: result = pFire13
  of 14: result = pFire14
  of 15: result = pFire15
  of 16: result = pFire16
  of 17: result = pFire17
  else:  result = pFire18

proc armProbes() =
  ## Binds all 19 drains, once. Each refusal is STATED with its site name --
  ## a probe that was never installed and a probe that never fired look
  ## identical in a counter, and the heartbeat is written so they cannot be
  ## confused (`bound=n/19`).
  if gProbeArmed:
    return
  gProbeArmed = true
  for i in 0 ..< NProbe:
    let why = verifyTarget(ProbeRva[i], ProbeName[i], hex16(ProbeProlog[i]))
    if why.len > 0:
      inc gProbeRefused
      warn "ammoloading  probe NOT bound: " & ProbeName[i] & " -- " & why
      continue
    let spec = ProbeName[i] & "@0x" & rvaHex(ProbeRva[i]) & "/" &
               ProbeShape[i] & "!" & ProbeProlog[i]
    let st = hookTyped(spec, probeHandler(i))
    if st != Ok:
      inc gProbeRefused
      warn "ammoloading  hookTyped refused probe " & ProbeName[i] &
           " @0x" & rvaHex(ProbeRva[i]) & ": " & lastError()
      continue
    gProbeBound[i] = true
    inc gProbeBoundN
  info "ammoloading  probe bank bound " & $gProbeBoundN & "/" & $NProbe &
       " sites (" & $gProbeRefused & " refused). All UNIQUE, all PREFIX, all " &
       "read-only. See docs/AMMO-LOADING-MAP.md for how each RVA was measured."

proc probeKindFires(k: int): int64 =
  result = 0'i64
  for i in 0 ..< NProbe:
    if ProbeKind[i] == k:
      result = result + gProbeFires[i]

proc probeKindBound(k: int): int =
  result = 0
  for i in 0 ..< NProbe:
    if ProbeKind[i] == k and gProbeBound[i]:
      inc result

proc probeCensus(): string =
  ## One entry per site that has fired, plus the kind totals. Sites that never
  ## fired are summarised as a count, not listed, so a 19-line block does not
  ## drown the verdict.
  var fired = ""
  var silent = 0
  for i in 0 ..< NProbe:
    if not gProbeBound[i]:
      continue
    if gProbeFires[i] == 0'i64:
      inc silent
      continue
    fired.add " | " & ProbeKindName[ProbeKind[i]] & " " & ProbeName[i] &
              " fired " & $gProbeFires[i] & " times" &
              (if gProbeKlass[i].len > 0: " klass?=" & gProbeKlass[i] else: "")
  result = "bound=" & $gProbeBoundN & "/" & $NProbe
  for k in 0 ..< PkCount:
    result.add "  " & ProbeKindName[k] & "=" & $probeKindFires(k) &
               "(" & $probeKindBound(k) & " bound)"
  result.add "  silentSites=" & $silent & fired

proc probeVerdict(): string =
  ## THE NEGATIVE. Three outcomes, never two.
  ##
  ## The property asserted is a property of the FINISHED STATE of the run, and
  ## it is falsifiable: if the local player reloaded (an `input` site was
  ## entered) and NO ammo-change site was entered, then §3.3 of
  ## `docs/AMMO-LOADING-MAP.md` names the wrong methods and this must read FAIL.
  ##
  ## `anim` alone is deliberately NOT accepted as proof the player reloaded:
  ## MEASURED, 7 of the 13 call sites of FirearmsAnimator::Reload(bool) are
  ## NextObservedPlayer hands operations, so a bot reloading nearby increments
  ## it. A check a bot can satisfy is a check that cannot fail.
  if gProbeBoundN == 0:
    return "INCONCLUSIVE (no probe bound -- every zero below is that, not evidence)"
  let inp  = probeKindFires(PkInput)
  let ammo = probeKindFires(PkAmmo)
  let ops  = probeKindFires(PkOpStart)
  let anim = probeKindFires(PkAnim)
  let inv  = probeKindFires(PkInv)
  if inp == 0'i64 and ops == 0'i64 and inv == 0'i64:
    return "INCONCLUSIVE -- no local reload and no inventory magazine action " &
           "was observed this run" &
           (if anim > 0'i64:
              " (anim fired " & $anim & ", but that also counts OTHER players " &
              "and is not evidence about this one)"
            else: "") &
           ". Nobody reloaded, so this says nothing about the mapping."
  if inp > 0'i64 and ammo == 0'i64:
    return "FAIL -- the local player reloaded (input=" & $inp & ", opstart=" &
           $ops & ") and NOT ONE ammo-change site was entered. The ammo half " &
           "of docs/AMMO-LOADING-MAP.md section 3.3 names the wrong methods."
  if inp > 0'i64 and ammo > 0'i64:
    return "PASS -- input=" & $inp & " opstart=" & $ops & " ammo=" & $ammo &
           ". The reload path and the ammo-change site were BOTH entered; the " &
           "census above names the receiver at each."
  if inv > 0'i64:
    return "INVENTORY-ONLY -- inv=" & $inv & " and input=0. The magazine " &
           "action observed was an inventory fill/empty, not a weapon reload. " &
           "Which of PlayerInventoryController::LoadMagazine (in raid) and " &
           "ItemController::LoadMagazine (out of raid) fired is in the census."
  result = "INCONCLUSIVE -- opstart=" & $ops & " with input=0 and ammo=0, " &
           "which no branch above predicts. Read the census, not this line."

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
  # Deliberately NOT gated on LoadMagazineProcess::Start verifying. That
  # target is the one measured to be off the player's reload path, and making
  # the probe bank -- the instrument that proves it -- conditional on it would
  # be a check that cannot fail.
  result = true

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
    warn "ammoloading  NOT hooking LoadMagazineProcess::Start: " & whyStart
    return false
  let whyCtor = verifyTarget(TgtFactoryCtorRva, "EFT.ObjectsFactory::.ctor",
                             FactoryCtorProlog)
  if whyCtor.len > 0:
    warn "ammoloading  NOT hooking EFT.ObjectsFactory::.ctor: " & whyCtor &
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
    warn "ammoloading  the runtime has no il2cpp_string_new, so no resource " &
         "key or animator state name can be built -- running at most in " &
         "`read`. This is a refusal that says so, not a silent degradation."

  # THE PROBE BANK FIRST. It is the instrument that decides whether the
  # LoadMagazineProcess hooks below are on the player's path at all, and it is
  # bound before them so that a refusal of one cannot hide the other.
  armProbes()

  let st = hookTyped(TgtStart, onLoadMagazineStart)
  if st != Ok:
    warn "ammoloading  hookTyped refused LoadMagazineProcess::Start: " &
         lastError() & " -- the probe bank above is unaffected and stays " &
         "bound; only the inventory-load feature is unavailable."
    gArmed = true
    return true
  if whyCtor.len == 0:
    let st2 = hookTyped(TgtFactoryCtor, onFactoryCtor)
    if st2 != Ok:
      warn "ammoloading  hookTyped refused EFT.ObjectsFactory::.ctor: " &
           lastError() & " -- the EasyAssets latch is unavailable."

  # The broad probe. Verified and installed exactly like the others; a refusal
  # is stated, never swallowed, because a MISSING probe and a probe that NEVER
  # FIRED look identical in the heartbeat unless the heartbeat knows which.
  let whyPCtor = verifyTarget(TgtProcCtorRva, "LoadMagazineProcess::.ctor",
                              ProcCtorProlog)
  if whyPCtor.len > 0:
    warn "ammoloading  NOT hooking the broad probe LoadMagazineProcess::.ctor: " &
         whyPCtor & " -- the heartbeat will report ctorProbe=NOT INSTALLED, " &
         "so a zero there must NOT be read as 'never constructed'."
  else:
    let st4 = hookTyped(TgtProcCtor, onLoadMagazineProcCtor)
    if st4 == Ok:
      gCtorHooked = true
    else:
      warn "ammoloading  hookTyped refused the broad probe " &
           "LoadMagazineProcess::.ctor: " & lastError()

  let whyEnd = verifyTarget(TgtEndRva, "LoadMagazineProcess::RaiseLoadEventArgs",
                            EndProlog)
  if whyEnd.len > 0:
    warn "ammoloading  NOT hooking LoadMagazineProcess::RaiseLoadEventArgs: " &
         whyEnd & " -- sessions will close on the safety cap instead, which " &
         "will show up as a non-zero `timedOut`."
  else:
    let st3 = hookTyped(TgtEnd, onLoadMagazineEnd)
    if st3 != Ok:
      warn "ammoloading  hookTyped refused " &
           "LoadMagazineProcess::RaiseLoadEventArgs: " & lastError()

  gArmed = true
  success "ammoloading  ARMED in mode " & modeName(gMode) &
          "; reload PROBE BANK bound " & $gProbeBoundN & "/" & $NProbe &
          " (all UNIQUE, all PREFIX, all read-only -- " &
          "docs/AMMO-LOADING-MAP.md), inventory trigger " &
          "LoadMagazineProcess::Start @0x768F50, latch " &
          "ObjectsFactory::.ctor @0x938430. Vanilla magazine loading and " &
          "vanilla reloading are never suppressed on any rung."
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
           ",\"probeBound\":" & $gProbeBoundN &
           ",\"probeRefused\":" & $gProbeRefused &
           ",\"probeInput\":" & $probeKindFires(PkInput) &
           ",\"probeOpStart\":" & $probeKindFires(PkOpStart) &
           ",\"probeAnim\":" & $probeKindFires(PkAnim) &
           ",\"probeAmmo\":" & $probeKindFires(PkAmmo) &
           ",\"probeInv\":" & $probeKindFires(PkInv) &
           ",\"probeVerdict\":\"" & probeVerdict().replace("\"", "'") & "\"" &
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
  ## reachable only through `serve("/aowlspt/ammoloading/stats")` -- a route
  ## the GAME PROCESS CANNOT SERVE, because the client host runs no HTTP
  ## server. The numbers existed and were unreadable by construction.
  if not gArmed:
    return "ammoloading  NOT ARMED" &
           (if not gEnabled: " (enabled=false)"
            elif gMode == ModeOff: " (mode=off)"
            elif not gArmTried: " (waiting out armDelayMs)"
            else: " (arming was TRIED and REFUSED -- see the warn above)") &
           ". No hook is installed, so every counter below would be zero for " &
           "that reason alone. This is NOT evidence about the trigger, and " &
           "the reload PROBE BANK is not bound either."

  let probeState =
    if not gCtorHooked: "NOT INSTALLED"
    elif gCtorFires == 0'i64: "installed, never fired"
    else: "fired " & $gCtorFires

  # THE PROBE BANK IS THE VERDICT NOW.
  #
  # The old text here said "LoadMagazineProcess::Start has been entered ZERO
  # times ... if a magazine was loaded, the identification is wrong". It was
  # right, and it printed for a whole raid. `docs/AMMO-LOADING-MAP.md` settles
  # the why (that type is the INVENTORY fill process, reachable from one async
  # body only), so the heartbeat no longer asks the reader to work it out -- it
  # reports the measured reload path directly.
  let bank = "  PROBES " & probeCensus() & "  VERDICT: " & probeVerdict()

  if gStartFires == 0'i64 and gCtorFires == 0'i64:
    return "ammoloading  mode=" & modeName(gMode) &
           ", latched=" & (if gLatched: "yes" else: "no") &
           ". LoadMagazineProcess::Start @0x768F50 entered 0 times and the " &
           "broad probe @0x768D40 is " & probeState & " -- EXPECTED: that " &
           "type is the inventory magazine-fill process, not the weapon " &
           "reload path (docs/AMMO-LOADING-MAP.md section 0)." & bank

  if gStartFires == 0'i64:
    return "ammoloading  broad probe " & probeState & ", " &
           "LoadMagazineProcess::Start @0x768F50 fired ZERO times -- the " &
           "inventory process was CONSTRUCTED and Start is not the method " &
           "that runs." & bank

  result = "ammoloading  ARMED and FIRING. mode=" & modeName(gMode) &
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
           " lastMesh=" & (if gSessionMesh.len == 0: "-" else: gSessionMesh) &
           bank
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
                category = "Animation",
                description = "Port of Manimal's Ammo Loading Animations (MIT). " &
                  "Plays a first-person animation of hands thumbing rounds into " &
                  "the magazine while it loads. DEFAULT OFF: this detours the " &
                  "live magazine-loading flow during gameplay. Vanilla loading " &
                  "is never suppressed -- the animation is added alongside it. This is ONE of this mod's two features; how LONG a load or unload takes is the OTHER, and it is NOT a knob here -- it is a server database value (globals.config.BaseLoadTime / BaseUnloadTime / LoadTimeSpeedProgress) already exposed by aowl.tarkov's Globals tuning page as 'Base Load Time', 'Base Unload Time' and 'Load Time Speed Progress'. Change it THERE. Declaring a second control for the same value here is how you get 'I changed it and nothing happened'."),
    enumSetting("mode", "Escalation rung", "off",
                @["off", "probe", "read", "spawn", "animate"],
                category = "Animation",
                description = "Move up ONE rung at a time. probe: count " &
                  "detections only. read: also resolve which magazine is being " &
                  "loaded (nothing called or written). spawn: also instantiate " &
                  "the animation prefab. animate: also play it -- only this rung " &
                  "is visible. Each rung is strictly additive over the one below."),
    stringSetting("bundlePath", "Bundle file", "",
                category = "Animation",
                description = "Absolute path to stanags_container.bundle, the " &
                  "upstream mod's shipped asset. A copy ships in this mod's " &
                  "data/ directory and is used when this is empty."),
    stringSetting("hijackKey", "Bundle key to ride", "",
                category = "Animation",
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
  probeInit()
  declareSettings(schema())
  gLoadedAtMs = nowMs()
  # NO `serve("/aowlspt/ammoloading/stats", onStats)` HERE, DELIBERATELY.
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
    info "ammoloading  disabled (enabled=false). No hook is installed and " &
         "magazine loading is exactly vanilla."
    return Ok
  if gMode == ModeOff:
    info "ammoloading  enabled but mode=off, so nothing is installed. Set " &
         "mode to `probe` and escalate one rung at a time."
    return Ok
  if gBundlePath.len == 0:
    info "ammoloading  bundlePath is empty; the copy shipped in this mod's " &
         "data/ directory is the one that will be used."
  info "ammoloading  will arm in " & $gArmDelayMs & "ms, mode " & modeName(gMode)
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
      warn "ammoloading  session closed by the SAFETY CAP after " & $ageMs &
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
