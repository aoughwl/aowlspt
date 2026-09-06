/* aowlspt_pact.h -- IN-RAID ACTUATION OF THE LOCAL PLAYER ("pact").
 *
 * The native half of `host/Aowlspt.Host.Il2Cpp/pact.nim`: a byte-verified
 * static-RVA call table plus one correctly-shaped C thunk per calling
 * convention, so that a scripted test run can walk, look, shoot, aim, reload,
 * swap weapons and cycle a magazine WITHOUT a human touching the keyboard.
 *
 * The motivating case is verbatim from the user: "i shouldn't have to unload
 * the magazine and reload the ammo for something to trigger for you to
 * observe". `AOWL_PACT_PIC_UNLOAD_MAG` / `AOWL_PACT_PIC_LOAD_MAG` below are
 * that case, reachable with no inventory-grid walk at all (see MAGAZINE).
 *
 * ===========================================================================
 * 1. THE BOT DRIVE PATH DOES NOT TRANSFER. MEASURED, NOT ASSUMED.
 * ===========================================================================
 *
 * `mods/sain/client/drivecalls.nim` drives BOTS through seven RVAs:
 *
 *     BotMover::Sprint            0x1A2D700
 *     BotMover::Stop              0x1A2D600
 *     BotSteering::LookToPoint    0x1A3B690
 *     ShootData::Shoot            0x1AF7940
 *     EFT.BotOwner::StopMove      0x81C970
 *     NavMesh::SamplePosition     0x5238930
 *     Physics::Raycast            0x5328830
 *
 * The last two are UnityEngine statics and are receiver-agnostic; a local-player
 * feature may call them unchanged. The FIRST FIVE cannot be pointed at the local
 * player, and the reason is structural rather than a matter of taste:
 *
 *   - `BotMover`, `BotSteering` and `ShootData` are reached ONLY through
 *     `EFT.BotOwner::get_Mover` @0x80F920 (field +0x3D0), `get_Steering`
 *     @0x80D8E0 (+0x148) and `get_ShootData` @0x80E8D0 (+0x280). Those are
 *     `BotOwner` field offsets. The local player is an `EFT.Player`; it is not a
 *     `BotOwner` and it does not hold one. `EFT.Player::get_AIData` @0x7267B0
 *     reads NULL for the local player -- that is the discriminator botdiag
 *     already uses to tell a bot from you.
 *   - `EFT.BotOwner::StopMove` likewise takes a `BotOwner` receiver.
 *   - Feeding an `EFT.Player*` to any of the five is TYPE CONFUSION: the callee
 *     reads a `BotOwner` field offset off a `Player`, gets a plausible pointer
 *     from an unrelated field, and dereferences it. `VirtualQuery` cannot see
 *     that and neither can a null check. It would not refuse; it would crash,
 *     or worse, silently drive garbage.
 *
 * So the honest answer to "can the local player ride the bot drive layer" is
 * NO -- the local player has its OWN, entirely separate and strictly richer
 * actuation surface, which is what this file binds. What CAN and SHOULD be
 * shared is the layer above: one verb vocabulary (moveTo / lookAt / fire /
 * reload) with two backends, `sain` drivecalls for a `BotOwner` and this file
 * for the `EFT.Player`. That is the fold-together, and it is a facade, not a
 * shared call table. Nothing here should ever be handed a BotOwner and nothing
 * in drivecalls.nim should ever be handed a Player.
 *
 * ===========================================================================
 * 2. HOW EVERY ROW WAS DERIVED
 * ===========================================================================
 *
 * `python tools\il2cpp_resolve.py D:\Aowlspt\GameAssembly.dll
 *  .cache\global-metadata.dec.dat <verb>`, build 1.1.0.1.46777, imagebase
 * 0x180000000. The mandatory self-check passed first, in the same session that
 * produced every row here: `verify-fields` / `fields System.String` printed
 * `_stringLength @ 0x10` and `_firstChar @ 0x14`.
 *
 * For EVERY row below, three things were measured and are recorded:
 *
 *   RVA         from `type <Type>` (per-image methodPointers, not a guess)
 *   sharedness  from `Resolver.sharedness(rva)` -- three-state. Every row is
 *               `unique` EXCEPT the three marked CALL-ONLY, which are folded
 *               one-instruction getters. Calling a shared RVA is correct code
 *               for the receiver passed. NOTHING IN THIS FILE IS DETOURED, so
 *               the shared ones are safe here; a future reader must not promote
 *               one to a detour target.
 *   prologue    the 16 bytes at the RVA, verbatim, verified at bind time
 *               against the STARTUP SNAPSHOT (`aowl_pro_verify`), never against
 *               live memory.
 *
 * NOT ONE ROW IS THE UNIVERSAL EMPTY STUB. `0x628110` is `C2 00 00` (`ret 0`),
 * shared by 6,438 methods on this build; `EFT.Player::ProceedLocalAbsorbedDamage`
 * and `GamePlayerOwner::Init` both resolve there and are therefore uncallable.
 * Every prologue below was eyeballed for that pattern and for `B0 01 C3`
 * (`mov al,1; ret`), which is how `FirearmController::CanPressTrigger`
 * @0x6B65D0 compiles -- a folded constant-true shared by 584 methods. It is
 * REFUSED as a fire gate for exactly that reason and does not appear here: a
 * gate that can only say yes is the defect CLAUDE.md 9b is about.
 *
 * ===========================================================================
 * 3. THE CALLING SHAPES, DERIVED FROM THE COMPILED BODIES
 * ===========================================================================
 *
 * Win64 + IL2CPP: instance `RCX=this`, then RDX/R8/R9, floats in XMM1..XMM3 at
 * the matching POSITION, then a hidden trailing `const MethodInfo*`. NULL is
 * fine here -- no row is a shared generic. Each shape is a separate C typedef
 * because a call through the wrong one is the defect that once handed
 * `Transform::set_localPosition` a NULL Vector3 pointer through a perfectly
 * valid, byte-verified function.
 *
 * The two that are NOT obvious were derived from the disassembly, not inferred:
 *
 *   Player::Move(Vector2)   @0x6F3B20
 *     ... 48 8B D9          mov  rbx, rcx        ; this
 *         66 48 0F 6E F2    movq xmm6, rdx       ; <-- THE VECTOR2 IS IN RDX
 *   So an 8-byte Vector2 travels as a PACKED INTEGER in the integer register,
 *   not in XMM. Win64 has no HFA rule; a 1/2/4/8-byte struct is passed as an
 *   integer of that size. Shape: (void* this, uint64_t packed, void* mi).
 *   `packed` low dword = x, high dword = y.
 *
 *   Player::Rotate(Vector2, bool)  @0x6F4260
 *         41 0F B6 F8       movzx edi, r8b       ; the bool is in R8
 *         66 48 0F 6E F2    movq  xmm6, rdx      ; the Vector2 is in RDX
 *   Shape: (void* this, uint64_t packed, int32_t flag, void* mi).
 *
 *   Player::ChangePose(float) @0x6F3BE0 -- `0F 28 F1 movaps xmm6,xmm1`: the
 *   float is in XMM1, i.e. argument slot 1. Ordinary.
 *   Player::EnableSprint(bool) @0x6F5190 -- `0F B6 FA movzx edi,dl`: DL.
 *
 *   MovementContext::CalculateLookAtDirection(Vector3,Vector3,float) @0x88C080
 *         48 8B 41 40       mov   rax,[rcx+0x40] ; this IS in RCX -> no sret
 *         49 8B D8          mov   rbx, r8        ; playerPos ptr
 *         48 8B FA          mov   rdi, rdx       ; target ptr
 *         0F 28 F3          movaps xmm6, xmm3    ; relativeRootHeight
 *   A 12-byte Vector3 is > 8 bytes so it is passed BY ADDRESS; the 8-byte
 *   Vector2 return comes back PACKED IN RAX with no hidden return buffer,
 *   which is proved by `this` occupying RCX rather than slot 1.
 *   Shape: (void* this, void* pTarget, void* pPlayerPos, float h, void* mi)
 *          -> uint64_t.
 *
 * ===========================================================================
 * 4. MAGAZINE LOAD / UNLOAD -- the user's own example, with no inventory walk
 * ===========================================================================
 *
 * The obvious route to `LoadMagazine` needs an `Ammo` stack found by walking
 * Inventory -> Equipment -> slots -> grids -> items and matching a template.
 * Every offset in that walk would have to be measured and every hop guarded,
 * and a wrong one reads a plausible pointer. It is NOT the route taken.
 *
 * The route taken reaches a type-correct `Ammo` in four hops from a live,
 * already-validated `EFT.Player`, each hop a byte-verified call whose return
 * type the metadata states:
 *
 *   Player.HasFirearmInHands()        @0x727770  -- THE TYPE GUARD, see below
 *   Player.get_HandsController()      @0x727850  -> AbstractHandsController
 *   FirearmController.get_Item()      @0x7771D0  -> Weapon
 *   Weapon.GetCurrentMagazine()       @0x10B48F0 -> Magazine
 *   Magazine.FirstRealAmmo()          @0x10982F0 -> Item (an Ammo stack)
 *   Magazine.get_Count()              @0x10982C0 -> int   (the READBACK)
 *
 * then
 *
 *   PlayerInventoryController.UnloadMagazine(Magazine, bool)          @0x766BC0
 *   PlayerInventoryController.LoadMagazine(Ammo, Magazine, int, bool) @0x766930
 *
 * with the receiver from `Player.get_InventoryController()` @0x727B20.
 *
 * THE TYPE GUARD IS LOAD-BEARING AND IS NOT OPTIONAL. `get_HandsController`
 * returns the ABSTRACT base. If the player is holding a knife, a grenade or
 * nothing, calling `FirearmController::get_Item` on that pointer reads a
 * FirearmController field offset off an unrelated object -- textbook type
 * confusion, which `aowl_is_readable` cannot see and a null check passes.
 * `EFT.Player::HasFirearmInHands()` @0x727770 is the GAME'S OWN answer to
 * exactly that question, it is arity-0, unique, and it takes the Player we
 * already trust. pact.nim calls it and refuses out loud on false. There is no
 * path in this file that reaches `get_Item` without it.
 *
 * BOTH INVENTORY CALLS RETURN `Task<IResult>` -- they are ASYNCHRONOUS. The
 * returned pointer is ignored (nothing is allocated by us and nothing managed
 * is retained). Completion is therefore NOT observable at the call site, which
 * is why pact.nim POLLS `Magazine.get_Count()` over a bounded number of frames
 * and reports three outcomes -- took / issued-but-count-never-changed /
 * never-issued -- rather than echoing the fact that it made the call.
 *
 * `PlayerInventoryController::LoadMagazine` and `::UnloadMagazine` are both
 * `VIRTUAL` and NOT sealed. A direct call at the RVA runs THIS body even for a
 * derived receiver that overrides it. That residual risk is REAL and is stated
 * rather than hidden: the receiver comes from `Player::get_InventoryController`
 * on the local player, which in an offline raid is a `PlayerInventoryController`,
 * and this build gives us no ungated way to ask an object its class. pact.nim
 * PINS the klass word on first acquisition and refuses on any change, which
 * catches a swap but not a wrong first answer.
 *
 * ===========================================================================
 * 5. THE COMMAND CHANNEL, AND WHY IT IS THE MOST VALUABLE ROW HERE
 * ===========================================================================
 *
 * `EFT.GamePlayerOwner::TranslateCommand(ECommand) -> ETranslateResult`
 * @0xB2B2F0, unique, real body. This is the single funnel every in-raid keybind
 * goes through, so ONE correctly-shaped call covers 88 verbs including
 * ReloadWeapon(16), QuickReloadWeapon(19), ChangeWeaponMode(20),
 * SelectFirstPrimaryWeapon(41) / SelectSecondPrimaryWeapon(42) /
 * SelectSecondaryWeapon(43), ToggleInventory(37), CheckAmmo(58),
 * ToggleShooting(1) / EndShooting(2), Jump(40), ToggleDuck(22), ToggleProne(28).
 * `CanTranslateCommand` @0xB2A830 is the game's own pre-check and is called
 * first, so a command the game would refuse is reported as REFUSED rather than
 * issued into the void.
 *
 * REACHING THE RECEIVER IS THE PROBLEM, AND THE SOLUTION IS EMPIRICAL.
 * `GamePlayerOwner` is a MonoBehaviour. There is NO field on `EFT.Player` that
 * points at it -- `holdersof GamePlayerOwner` returns only compiler closure
 * classes, `RaidDialogEntryPoint._gamePlayerOwner` and
 * `EftBattleUIScreenController.<Owner>k__BackingField`, none of which we hold.
 * A `GetComponent` by name is token-gated on this build and its failure mode is
 * a uniform random non-zero pointer, so that route is not merely awkward, it is
 * lethal.
 *
 * So the instance is CAPTURED, not walked: a read-only detour on
 * `EFT.GamePlayerOwner::LateUpdate` @0xB29130 (unique, owners=1, real body)
 * records RCX and returns. It writes nothing, allocates nothing, and calls
 * nothing. It runs on the Unity main thread by construction, because that is
 * where LateUpdate runs. Nothing else in this repo detours 0xB29130 -- checked
 * before binding -- so the double-detour trampoline hazard does not apply.
 * Until that detour has fired at least once the command channel reports
 * NOT-YET-CAPTURED, which is INCONCLUSIVE and is never reported as a refusal
 * about the build.
 *
 * ===========================================================================
 * 6. WHAT IS DELIBERATELY ABSENT
 * ===========================================================================
 *
 *   FirearmController::CanPressTrigger @0x6B65D0
 *       `B0 01 C3` = `mov al,1; ret`, SHARED by 584 methods. A folded
 *       constant-true. Bindable, verifiable, and completely useless as a gate.
 *       REFUSED.
 *   FirearmController::ReloadMag / QuickReloadMag / ReloadWithAmmo / ReloadBarrels
 *       every overload takes one or two managed `Callback` delegates. Building
 *       one needs runtime managed type/delegate construction, which this repo
 *       records as PLAUSIBLE BUT UNVERIFIED. Passing NULL is not obviously safe
 *       and was not measured. REFUSED -- use ECommand ReloadWeapon(16) instead,
 *       which is the same operation through the game's own entry point.
 *   EFT.Player::Proceed(Weapon, Callback<IFirearmHandsController>, bool)
 *       @0x742710 and its ten siblings -- same Callback problem. REFUSED for
 *       weapon swap; use ECommand SelectFirstPrimaryWeapon(41) et al.
 *   EFT.Player::Create, MovementContext::Create -- RVA=None in the metadata
 *       (generic/`mvar`); not resolvable offline and not wanted.
 *
 * ===========================================================================
 * 7. SAFETY
 * ===========================================================================
 *
 * Everything in this header is either a pure accessor over a static table or a
 * thunk that (a) null-checks fn and self, (b) rejects NaN and absurd magnitudes
 * before they reach the game, and (c) makes exactly one call. There is no loop,
 * no allocation and no state machine here. The guard (`aowl_p_p_seh`), the flag
 * gate, the fault budget, the pointer walk and the readback all live in
 * pact.nim, under ONE guard for the whole body, because that guard is not
 * re-entrant.
 *
 * Depends on `aowlspt_prologue.h` (aowl_pro_verify) and windows.h, both already
 * included by aowlhost.nim ahead of this file -- the same arrangement
 * aowlspt_camera.h uses.
 */

#ifndef AOWLSPT_PACT_H
#define AOWLSPT_PACT_H

typedef struct AowlPactTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlPactTarget;

/* Target indices. MUST match the PactT* constants in pact.nim; tools/idxbind.py
 * fails the build if the name at an index stops matching what the caller
 * believes is there. */
#define AOWL_PACT_PL_GET_POSITION      0
#define AOWL_PACT_PL_MOVE              1
#define AOWL_PACT_PL_ROTATE            2
#define AOWL_PACT_PL_JUMP              3
#define AOWL_PACT_PL_CHANGE_POSE       4
#define AOWL_PACT_PL_TOGGLE_PRONE      5
#define AOWL_PACT_PL_ENABLE_SPRINT     6
#define AOWL_PACT_PL_TOGGLE_SPRINT     7
#define AOWL_PACT_PL_GET_SPRINTING     8
#define AOWL_PACT_PL_TOGGLE_LEAN       9
#define AOWL_PACT_PL_GET_ISYOURPLAYER  10
#define AOWL_PACT_PL_GET_ISAI          11
#define AOWL_PACT_PL_HAS_FIREARM       12
#define AOWL_PACT_PL_GET_HANDS         13
#define AOWL_PACT_PL_GET_INVCTRL       14
#define AOWL_PACT_FC_SET_TRIGGER       15
#define AOWL_PACT_FC_TOGGLE_AIM        16
#define AOWL_PACT_FC_SET_AIMING        17
#define AOWL_PACT_FC_GET_AIMING        18
#define AOWL_PACT_FC_CHANGE_FIREMODE   19
#define AOWL_PACT_FC_CHECK_AMMO        20
#define AOWL_PACT_FC_GET_ITEM          21
#define AOWL_PACT_GPO_TRANSLATE        22
#define AOWL_PACT_GPO_CAN_TRANSLATE    23
#define AOWL_PACT_GPO_GET_MYPLAYER     24
#define AOWL_PACT_PIC_LOAD_MAG         25
#define AOWL_PACT_PIC_UNLOAD_MAG       26
#define AOWL_PACT_WP_CUR_MAGAZINE      27
#define AOWL_PACT_MG_GET_COUNT         28
#define AOWL_PACT_MG_FIRST_AMMO        29
#define AOWL_PACT_MC_LOOKAT_DIR        30
#define AOWL_PACT_MC_GET_ROTATION      31

static const AowlPactTarget aowl_pact_targets[] = {
    /* ---------------- EFT.Player, INSTANCE, Assembly-CSharp.dll ---------- */

    /* [0] Vector3 get_Position() rid=42008 arity=0 UNIQUE.
     * SRET: `48 8B 82 40 0B 00 00` loads through RDX, so slot 0 is the hidden
     * return buffer and slot 1 is `this`. Byte-identical to sain's `pPosition`
     * row, an independent corroboration. */
    { "EFT.Player::get_Position", 0x6F32C0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x82,0x40,0x0B,0x00,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [1] void Move(Vector2 direction) rid=42025 arity=1 UNIQUE.
     * `66 48 0F 6E F2 movq xmm6,rdx` -- the packed Vector2 is in RDX. */
    { "EFT.Player::Move", 0x6F3B20u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x0F,0x29,0x74,0x24,0x20,0x48,0x8B,
        0xD9,0x66,0x48 }, 16 },

    /* [2] void Rotate(Vector2 deltaRotation, bool ignoreClamp) rid=42040 UNIQUE.
     * `41 0F B6 F8 movzx edi,r8b` then `66 48 0F 6E F2` at +0x1D. */
    { "EFT.Player::Rotate", 0x6F4260u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x40,0x80,0x3D,0xFA,
        0x3D,0x9C,0x06 }, 16 },

    /* [3] void Jump() rid=42046 arity=0 UNIQUE. */
    { "EFT.Player::Jump", 0x6F4CE0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0x81,0x33,0x9C,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [4] void ChangePose(float poseDelta) rid=42026 UNIQUE.
     * `0F 28 F1 movaps xmm6,xmm1` -- the float is in XMM1. Negative crouches,
     * positive stands; the magnitude is a pose-level delta, not metres. */
    { "EFT.Player::ChangePose", 0x6F3BE0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x0F,0x29,0x74,0x24,0x20,0x33,0xD2,
        0x0F,0x28,0xF1 }, 16 },

    /* [5] void ToggleProne() rid=42060 arity=0 UNIQUE. */
    { "EFT.Player::ToggleProne", 0x6F5750u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x11,0x48,0x8B,0xD9,0x48,
        0x8B,0x82,0x08 }, 16 },

    /* [6] void EnableSprint(bool enable) rid=42051 UNIQUE.
     * `0F B6 FA movzx edi,dl` -- the bool is in DL. */
    { "EFT.Player::EnableSprint", 0x6F5190u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x0F,0xB6,0xFA,
        0x48,0x8B,0xD9 }, 16 },

    /* [7] void ToggleSprint() rid=42054 arity=0 UNIQUE. */
    { "EFT.Player::ToggleSprint", 0x6F52E0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0xD9,
        0x48,0x8B,0x89 }, 16 },

    /* [8] bool get_IsSprintEnabled() rid=42013 arity=0 UNIQUE. The READBACK for
     * [6]/[7]: a sprint that was asked for and did not take reads false here. */
    { "EFT.Player::get_IsSprintEnabled", 0x6F3540u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x41,0x60,0x48,0x85,0xC0,0x74,0x2D,
        0x48,0x8B,0x40 }, 16 },

    /* [9] void ToggleLean(float dir) rid=42015 UNIQUE. -1 left, 0 centre,
     * +1 right, by the game's own convention at the call sites. */
    { "EFT.Player::ToggleLean", 0x6F3610u,
      { 0x40,0x53,0x48,0x83,0xEC,0x40,0x80,0xB9,0xBC,0x00,0x00,0x00,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [10] bool get_IsYourPlayer() rid=42691 UNIQUE.
     * `0F B6 81 89 0B 00 00 / C3` -- a pure byte read at +0xB89 with NO
     * dereference, which is why it is safe to use as the FIRST identity probe
     * on a pointer we have only proved readable. It cannot fault on any object
     * of at least 0xB8A bytes and it cannot dispatch anywhere. */
    { "EFT.Player::get_IsYourPlayer", 0x73AF70u,
      { 0x0F,0xB6,0x81,0x89,0x0B,0x00,0x00,0xC3,0xCC,0xCC,0xCC,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* [11] bool get_IsAI() rid=42511 UNIQUE. The negative half of the identity
     * check: the local player must read false. */
    { "EFT.Player::get_IsAI", 0x726890u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xAA,0x18,0x99,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [12] bool HasFirearmInHands() rid=42524 arity=0 UNIQUE.
     * THE TYPE GUARD for every FirearmController row below. See section 4. */
    { "EFT.Player::HasFirearmInHands", 0x727770u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xD4,0x09,0x99,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [13] AbstractHandsController get_HandsController() rid=42525.
     * CALL-ONLY: SHARED with 2 other methods (owners=3) -- a folded
     * one-instruction getter `mov rax,[rcx+0xA40]; ret`. Calling it is correct
     * for the receiver passed. NEVER DETOUR THIS ADDRESS. */
    { "EFT.Player::get_HandsController", 0x727850u,
      { 0x48,0x8B,0x81,0x40,0x0A,0x00,0x00,0xC3,0xCC,0xCC,0xCC,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* [14] InventoryController get_InventoryController() rid=42528 UNIQUE. */
    { "EFT.Player::get_InventoryController", 0x727B20u,
      { 0x48,0x8B,0x81,0x38,0x0A,0x00,0x00,0xC3,0xCC,0xCC,0xCC,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* ------------- Player+FirearmController, INSTANCE ------------------- *
     * Every row below REQUIRES that HasFirearmInHands() [12] returned true for
     * the Player the hands controller came from. */

    /* [15] void SetTriggerPressed(bool pressed) rid=43317 UNIQUE. THE FIRE
     * PRIMITIVE. Held, not edge: press true, wait, press false. */
    { "FirearmController::SetTriggerPressed", 0x7827A0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,
        0xEC,0x20,0x0F }, 16 },

    /* [16] void ToggleAim() rid=43321 arity=0 UNIQUE. */
    { "FirearmController::ToggleAim", 0x782B00u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0xB9,0x60,0x01,0x00,0x00,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [17] void set_IsAiming(bool) rid=43170 UNIQUE. ABSOLUTE, where [16] is a
     * toggle; a script that wants "aim down sights" and cannot observe the
     * current state must use this one. */
    { "FirearmController::set_IsAiming", 0x777A90u,
      { 0x48,0x89,0x5C,0x24,0x18,0x56,0x48,0x83,0xEC,0x30,0x80,0x3D,0x52,
        0x08,0x94,0x06 }, 16 },

    /* [18] bool get_IsAiming() rid=43169. CALL-ONLY: SHARED, owners=3 -- a
     * folded byte read at +0x105. The READBACK for [16]/[17]. NEVER DETOUR. */
    { "FirearmController::get_IsAiming", 0x777A80u,
      { 0x0F,0xB6,0x81,0x05,0x01,0x00,0x00,0xC3,0xCC,0xCC,0xCC,0xCC,0xCC,
        0xCC,0xCC,0xCC }, 16 },

    /* [19] bool ChangeFireMode(EFireMode) rid=43333 UNIQUE. */
    { "FirearmController::ChangeFireMode", 0x783AC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x4F,
        0x48,0x93,0x06 }, 16 },

    /* [20] bool CheckAmmo() rid=43337 arity=0 UNIQUE. */
    { "FirearmController::CheckAmmo", 0x7840C0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x57,0x42,0x93,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [21] Weapon get_Item() rid=43143 arity=0 UNIQUE. First hop of the
     * magazine chain. */
    { "FirearmController::get_Item", 0x7771D0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x11,0x11,0x94,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* ---------------- EFT.GamePlayerOwner, INSTANCE --------------------- */

    /* [22] ETranslateResult TranslateCommand(ECommand) rid=55191 UNIQUE.
     * THE COMMAND CHANNEL. See section 5. */
    { "EFT.GamePlayerOwner::TranslateCommand", 0xB2B2F0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xEE,
        0xE5,0x58,0x06 }, 16 },

    /* [23] bool CanTranslateCommand(ECommand) rid=55186 UNIQUE. The game's own
     * pre-check, so "the game would not accept this command right now" reads
     * differently from "we never issued it". */
    { "EFT.GamePlayerOwner::CanTranslateCommand", 0xB2A830u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xA9,
        0xF0,0x58,0x06 }, 16 },

    /* [24] Player get_MyPlayer() rid=55145 UNIQUE. The CORROBORATION for the
     * captured owner: the Player it names must be pointer-identical to the
     * GameWorld.MainPlayer we already validated, or the capture is rejected.
     * That is a check that CAN fail, which is the whole point. */
    { "EFT.GamePlayerOwner::get_MyPlayer", 0xB280D0u,
      { 0x48,0x83,0xEC,0x28,0x80,0x3D,0xF8,0x17,0x59,0x06,0x00,0x75,0x18,
        0x48,0x8D,0x0D }, 16 },

    /* ------------- PlayerInventoryController, INSTANCE ------------------ */

    /* [25] Task<IResult> LoadMagazine(Ammo sourceAmmo, Magazine magazine,
     *      int loadCount, bool ignoreRestrictions) rid=42899 UNIQUE.
     * VIRTUAL, NOT sealed -- see the hazard note in section 4. ASYNC. */
    { "PlayerInventoryController::LoadMagazine", 0x766930u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,
        0x24,0x18,0x57 }, 16 },

    /* [26] Task<IResult> UnloadMagazine(Magazine magazine, bool equipmentBlocked)
     * rid=42900 UNIQUE. VIRTUAL, NOT sealed. ASYNC. */
    { "PlayerInventoryController::UnloadMagazine", 0x766BC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0x80,0x00,0x00,0x00,
        0x80,0x3D,0xBA }, 16 },

    /* ---------------- EFT.InventoryLogic.Weapon / Magazine --------------- */

    /* [27] Magazine GetCurrentMagazine() rid=74810 arity=0 UNIQUE. */
    { "EFT.InventoryLogic.Weapon::GetCurrentMagazine", 0x10B48F0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x6B,0x73,0x00,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* [28] int get_Count() rid=74061 arity=0 UNIQUE. THE READBACK for both
     * inventory calls. Note [28] and [29] have IDENTICAL first sixteen bytes
     * at DIFFERENT addresses; the verify is per-RVA so that is harmless, but it
     * is called out because a reader diffing this table will notice. */
    { "EFT.InventoryLogic.Magazine::get_Count", 0x10982C0u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x89,0xA8,0x00,0x00,0x00,0x48,0x85,
        0xC9,0x74,0x0B }, 16 },

    /* [29] Item FirstRealAmmo() rid=74062 arity=0 UNIQUE. How a type-correct
     * `Ammo` is obtained with NO inventory-grid walk. */
    { "EFT.InventoryLogic.Magazine::FirstRealAmmo", 0x10982F0u,
      { 0x48,0x83,0xEC,0x28,0x48,0x8B,0x89,0xA8,0x00,0x00,0x00,0x48,0x85,
        0xC9,0x74,0x0B }, 16 },

    /* ---------------- EFT.MovementContext, INSTANCE ---------------------- */

    /* [30] Vector2 CalculateLookAtDirection(Vector3 target, Vector3 playerPos,
     *      float relativeRootHeight) rid=47794 UNIQUE.
     * The game's OWN world-point -> look-delta conversion, so `lookAt` is not a
     * trigonometry guess of ours. Shape derived in section 3. */
    { "EFT.MovementContext::CalculateLookAtDirection", 0x88C080u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,
        0x48,0x8B,0x41 }, 16 },

    /* [31] Vector2 get_Rotation() rid resolved by name, arity=0, UNIQUE
     * (owners=1, `il2cpp_resolve.py ... shared 0x8947A0`). THE ROTATION
     * READBACK, and the reason `look` is no longer issue-only.
     *
     * The player's aim is x = yaw in degrees, y = pitch; `Player::Rotate` writes
     * through to this same context. Reading it back after a Rotate is therefore
     * the game's own number, not an echo of our write -- which is exactly what
     * `look` had lacked and why every `actuated(s, "look ...")` was correctly
     * reporting INCONCLUSIVE.
     *
     * Vector2 is 8 bytes, so Win64 returns it PACKED IN RAX -- the same measured
     * ABI the inspector's `rect` verb uses, and the same shape as
     * CalculateLookAtDirection's return above. It is NOT an sret.
     *
     * The prologue is a real body (`push rbx; sub rsp,0x20;` then the class-init
     * check `cmp byte [rip+0x68241E6],0`), not the `C2 00 00` universal empty
     * stub that 6,438 methods share. */
    { "EFT.MovementContext::get_Rotation", 0x8947A0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xE6,0x41,0x82,0x06,0x00,
        0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_PACT_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_pact_targets) / sizeof(aowl_pact_targets[0])))

/* ---------------- MEASURED field offsets (raw reads only) ---------------- *
 * From Il2CppMetadataRegistration.fieldOffsets on the same GameAssembly.dll,
 * in the same session whose System.String self-check passed. The GameWorld and
 * Player rows are the SAME numbers abi/aowlspt_botdiag.h already carries and
 * raidphase.nim already consumes live; they are repeated rather than shared so
 * a future divergence is visible, and any disagreement between the two files is
 * a bug in one of them. */
#define AOWL_PACT_GW_MAINPLAYER  0x230   /* EFT.GameWorld.MainPlayer : Player  */
#define AOWL_PACT_PL_ISYOU       0xB89   /* EFT.Player.IsYourPlayer  : bool    */
#define AOWL_PACT_PL_AIDATA      0xA00   /* EFT.Player.AIData : IAIData.
                                          * MEASURED 2026-09-06 (DEPLOYED PvE
                                          * raid): the LOCAL player has one too
                                          * (0x1efb3ec3480), so "NULL means
                                          * you" is FALSE on this build and
                                          * pact no longer gates on it; it is
                                          * read for the log only. botdiag's
                                          * bot-vs-you discriminator is the
                                          * same test -- re-check it.        */
#define AOWL_PACT_PL_MOVECTX     0x060   /* EFT.Player.MovementContext.
                                          * Corroborated by the compiled body of
                                          * get_MovementContext @0x690D20,
                                          * which IS `mov rax,[rcx+0x60]; ret`.
                                          * Read RAW rather than called, because
                                          * that RVA is folded with 135 other
                                          * one-instruction getters.           */

static int32_t aowl_pact_off_gw_mainplayer(void) { return AOWL_PACT_GW_MAINPLAYER; }
static int32_t aowl_pact_off_pl_isyou(void)      { return AOWL_PACT_PL_ISYOU; }
static int32_t aowl_pact_off_pl_aidata(void)     { return AOWL_PACT_PL_AIDATA; }
static int32_t aowl_pact_off_pl_movectx(void)    { return AOWL_PACT_PL_MOVECTX; }

/* ---------------- ECommand ordinals, from `enum ECommand` ---------------- *
 * Decoded by il2cpp_resolve.py's constant decoder, whose `verify-consts` check
 * is asserted against 19 independently-known values. Only the ones a scripted
 * test actually issues are named here; the enum has 88 members and copying all
 * of them in would be transcription with no call site to keep it honest. */
#define AOWL_PACT_CMD_TOGGLE_SHOOTING     1
#define AOWL_PACT_CMD_END_SHOOTING        2
#define AOWL_PACT_CMD_RELOAD_WEAPON      16
#define AOWL_PACT_CMD_QUICK_RELOAD       19
#define AOWL_PACT_CMD_CHANGE_WEAPON_MODE 20
#define AOWL_PACT_CMD_TOGGLE_DUCK        22
#define AOWL_PACT_CMD_TOGGLE_SPRINTING   24
#define AOWL_PACT_CMD_TOGGLE_PRONE       28
#define AOWL_PACT_CMD_EXAMINE_WEAPON     36
#define AOWL_PACT_CMD_TOGGLE_INVENTORY   37
#define AOWL_PACT_CMD_JUMP               40
#define AOWL_PACT_CMD_SEL_PRIMARY1       41
#define AOWL_PACT_CMD_SEL_PRIMARY2       42
#define AOWL_PACT_CMD_SEL_SECONDARY      43
#define AOWL_PACT_CMD_CHECK_AMMO         58

/* ---------------- bind + verify ---------------- *
 * Identical in structure to aowl_cam_fn, and deliberately so: an absent module
 * handle is a fact about WHEN we asked, never about the build, so it is
 * RETRYABLE and is never latched into the rejected counter. Only a genuine
 * prologue mismatch latches. */

static int32_t       aowl_pact_verified = 0;
static int32_t       aowl_pact_rejected = 0;
static unsigned char aowl_pact_state[AOWL_PACT_TARGET_COUNT];
static int32_t       aowl_pact_last_reason = 0;
static int32_t       aowl_pact_waits = 0;

static HMODULE aowl_pact_ga(void) { return GetModuleHandleA("GameAssembly.dll"); }
static int32_t aowl_pact_module_ready(void) { return aowl_pact_ga() ? 1 : 0; }
static int32_t aowl_pact_wait_count(void)   { return aowl_pact_waits; }

static void* aowl_pact_fn(int32_t i) {
    HMODULE ga;
    const AowlPactTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    if (i < 0 || i >= AOWL_PACT_TARGET_COUNT) { aowl_pact_last_reason = 6; return NULL; }
    ga = aowl_pact_ga();
    if (!ga) { aowl_pact_waits++; aowl_pact_last_reason = 1; return NULL; }
    t = &aowl_pact_targets[i];
    p = (unsigned char*)ga + t->rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { aowl_pact_last_reason = 2; return NULL; }
    if (mbi.State != MEM_COMMIT) { aowl_pact_last_reason = 3; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_pact_last_reason = 4;
        return NULL;
    }
    /* STARTUP SNAPSHOT, not live memory: verifying against live bytes after
     * another feature has patched a function reads the trampoline and
     * self-rejects, which is a hook-order problem misreported as a bad RVA. */
    if (t->siglen > 0 && !aowl_pro_verify(t->rva, t->sig, t->siglen)) {
        /* A CONFIDENTLY WRONG DIAGNOSTIC, DISARMED. `aowl_pro_verify` fails
         * CLOSED and returns 0 for two completely different reasons: the bytes
         * really differ, OR the shared snapshot table was FULL and the row was
         * never captured. Reporting the second as the first announces "this
         * client build changed" when what actually happened is our own table
         * ran out of rows.
         *
         * This used to reconstruct the distinction locally, from `aowl_pro_have`
         * plus a non-zero full-count -- a good inference, but pact was the ONLY
         * caller that made it, so every other feature in the host still reported
         * exhaustion as a build change. The prologue header now states the
         * reason directly and every caller asks it. MEASURED at the time this
         * changed: 155 distinct RVAs were being asked of a 128-row table, so the
         * exhaustion this guard was written against was real and pact, being
         * captured last, wore almost all of it. */
        if (aowl_pro_last_was_table_full()) {
            aowl_pact_last_reason = 8;
            return NULL;            /* RETRYABLE-ish, and NEVER latched */
        }
        if (aowl_pact_state[i] == 0) { aowl_pact_state[i] = 2; aowl_pact_rejected++; }
        aowl_pact_last_reason = 5;
        return NULL;
    }
    /* THE EMPTY-STUB CHECK, at bind time and not only in review. `C2 00 00` is
     * this build's universal empty body, shared by 6,438 methods; `B0 01 C3` is
     * a folded constant-true. Either one passes a prologue compare against
     * itself perfectly well, so the snapshot check above cannot catch it. A
     * target that IS one of those is a target that binds and drives nothing --
     * the single worst outcome available -- so it is refused by shape. */
    if ((p[0] == 0xC2 && p[1] == 0x00 && p[2] == 0x00) ||
        (p[0] == 0xB0 && p[1] == 0x01 && p[2] == 0xC3)) {
        if (aowl_pact_state[i] == 0) { aowl_pact_state[i] = 2; aowl_pact_rejected++; }
        aowl_pact_last_reason = 7;
        return NULL;
    }
    if (aowl_pact_state[i] == 0) { aowl_pact_state[i] = 1; aowl_pact_verified++; }
    aowl_pact_last_reason = 0;
    return (void*)p;
}

static const char* aowl_pact_name(int32_t i) {
    if (i < 0 || i >= AOWL_PACT_TARGET_COUNT) return "";
    return aowl_pact_targets[i].name;
}
static uint32_t aowl_pact_rva(int32_t i) {
    if (i < 0 || i >= AOWL_PACT_TARGET_COUNT) return 0u;
    return aowl_pact_targets[i].rva;
}
static int32_t aowl_pact_target_count(void) { return AOWL_PACT_TARGET_COUNT; }
static int32_t aowl_pact_ok_count(void)     { return aowl_pact_verified; }
static int32_t aowl_pact_bad_count(void)    { return aowl_pact_rejected; }
static int32_t aowl_pact_reason(void)       { return aowl_pact_last_reason; }
static const char* aowl_pact_reason_text(void) {
    switch (aowl_pact_last_reason) {
        case 0: return "ok";
        case 1: return "GameAssembly.dll is not mapped yet (RETRYABLE -- not a "
                       "statement about the build)";
        case 2: return "VirtualQuery failed on the target address";
        case 3: return "the target page is not committed";
        case 4: return "the target page is not executable";
        case 5: return "the 16-byte prologue did not match the startup snapshot";
        case 6: return "target index out of range";
        case 7: return "the target IS an empty/constant stub (C2 00 00 or "
                       "B0 01 C3) -- it would bind and drive nothing";
        case 8: return "the SHARED PROLOGUE SNAPSHOT TABLE IS FULL "
                       "(AOWL_PRO_MAX_ROWS in aowlspt_prologue.h) so this "
                       "target's original bytes could never be recorded. This "
                       "is NOT a statement about the client build and is NOT "
                       "a prologue mismatch -- turn a feature off or raise the "
                       "cap";
        default: return "unknown";
    }
}

/* ---------------- the thunks ---------------- *
 * One typedef per genuinely different shape. The hidden trailing MethodInfo* is
 * a real declared parameter of the callee type in every one, passed NULL
 * explicitly, rather than hoping a register happens to be zero. No row here is
 * a shared generic, which is the only case where NULL is not acceptable. */

/* INSTANCE, 0 args -> void.  (this, MI*) */
typedef void (*AowlPact_V_P)(void*, void*);
static int32_t aowl_pact_v_p(void* fn, void* self) {
    if (!fn || !self) return 0;
    ((AowlPact_V_P)fn)(self, NULL);
    return 1;
}

/* INSTANCE, 0 args -> bool.  (this, MI*)
 * Returns 0/1 in the low bit and -1 for "could not ask", because a bool getter
 * that returns false and one that was never called must not be the same value.
 */
typedef unsigned char (*AowlPact_B_P)(void*, void*);
static int32_t aowl_pact_b_p(void* fn, void* self) {
    if (!fn || !self) return -1;
    return ((AowlPact_B_P)fn)(self, NULL) ? 1 : 0;
}

/* INSTANCE, 0 args -> pointer.  (this, MI*) */
typedef void* (*AowlPact_P_P)(void*, void*);
static void* aowl_pact_p_p(void* fn, void* self) {
    if (!fn || !self) return NULL;
    return ((AowlPact_P_P)fn)(self, NULL);
}

/* INSTANCE, 0 args -> int32.  (this, MI*)  -- Magazine::get_Count.
 * -1 means "could not ask"; a magazine legitimately holds 0. */
typedef int32_t (*AowlPact_I_P)(void*, void*);
static int32_t aowl_pact_i_p(void* fn, void* self) {
    if (!fn || !self) return -1;
    return ((AowlPact_I_P)fn)(self, NULL);
}

/* INSTANCE, one bool -> void.  (this, DL, MI*) */
typedef void (*AowlPact_V_PB)(void*, int32_t, void*);
static int32_t aowl_pact_v_pb(void* fn, void* self, int32_t b) {
    if (!fn || !self) return 0;
    ((AowlPact_V_PB)fn)(self, b ? 1 : 0, NULL);
    return 1;
}

/* INSTANCE, one float -> void.  (this, XMM1, MI*) */
typedef void (*AowlPact_V_PF)(void*, float, void*);
static int32_t aowl_pact_v_pf(void* fn, void* self, double v) {
    if (!fn || !self) return 0;
    if (v != v) return 0;                     /* NaN never reaches the game */
    if (v > 1.0e4 || v < -1.0e4) return 0;
    ((AowlPact_V_PF)fn)(self, (float)v, NULL);
    return 1;
}

/* INSTANCE, one PACKED Vector2 -> void.  (this, RDX = two floats, MI*)
 * Player::Move. The packing is done here, in C, from two doubles, so no caller
 * has to know that Win64 sends an 8-byte struct through the integer register.
 */
typedef void (*AowlPact_V_PU)(void*, unsigned long long, void*);
static int32_t aowl_pact_v_pu(void* fn, void* self, double x, double y) {
    float v[2];
    unsigned long long u;
    if (!fn || !self) return 0;
    if (x != x || y != y) return 0;
    if (x > 1.0e4 || x < -1.0e4 || y > 1.0e4 || y < -1.0e4) return 0;
    v[0] = (float)x; v[1] = (float)y;
    memcpy(&u, v, sizeof(u));
    ((AowlPact_V_PU)fn)(self, u, NULL);
    return 1;
}

/* INSTANCE, PACKED Vector2 + bool -> void.  (this, RDX, R8B, MI*)
 * Player::Rotate. */
typedef void (*AowlPact_V_PUB)(void*, unsigned long long, int32_t, void*);
static int32_t aowl_pact_v_pub(void* fn, void* self,
                               double x, double y, int32_t flag) {
    float v[2];
    unsigned long long u;
    if (!fn || !self) return 0;
    if (x != x || y != y) return 0;
    if (x > 1.0e4 || x < -1.0e4 || y > 1.0e4 || y < -1.0e4) return 0;
    v[0] = (float)x; v[1] = (float)y;
    memcpy(&u, v, sizeof(u));
    ((AowlPact_V_PUB)fn)(self, u, flag ? 1 : 0, NULL);
    return 1;
}

/* INSTANCE, one int32 -> int32.  (this, EDX, MI*)
 * TranslateCommand (ETranslateResult), CanTranslateCommand (bool widened),
 * ChangeFireMode (bool widened). -1 is "could not ask". */
typedef int32_t (*AowlPact_I_PI)(void*, int32_t, void*);
static int32_t aowl_pact_i_pi(void* fn, void* self, int32_t a) {
    if (!fn || !self) return -1;
    return ((AowlPact_I_PI)fn)(self, a, NULL);
}

/* INSTANCE, 0 args -> Vector3 by hidden buffer.  (retbuf, this, MI*)
 * Player::get_Position. Results land in statics because nimony cannot hand out
 * the address of an array element; every caller of this is on the Unity main
 * thread, single-threaded, and reads the three values immediately. */
typedef void (*AowlPact_SRET_P)(void*, void*, void*);
static double aowl_pact_v3[3] = { 0.0, 0.0, 0.0 };
static int32_t aowl_pact_get_v3(void* fn, void* self) {
    float ret[4];
    int i;
    if (!fn || !self) return 0;
    for (i = 0; i < 4; i++) ret[i] = 0.0f;
    ((AowlPact_SRET_P)fn)((void*)ret, self, NULL);
    for (i = 0; i < 3; i++) {
        float v = ret[i];
        if (v != v) return 0;
        /* A Tarkov world coordinate is a few hundred metres. 1e9 is not a
         * preference, it is a refusal: a half-torn-down transform must not feed
         * a plausible-looking number into a movement decision. */
        if (v > 1.0e9f || v < -1.0e9f) return 0;
    }
    for (i = 0; i < 3; i++) aowl_pact_v3[i] = (double)ret[i];
    return 1;
}
static double aowl_pact_v3x(void) { return aowl_pact_v3[0]; }
static double aowl_pact_v3y(void) { return aowl_pact_v3[1]; }
static double aowl_pact_v3z(void) { return aowl_pact_v3[2]; }

/* INSTANCE, (Vector3*, Vector3*, float) -> PACKED Vector2 in RAX.
 * MovementContext::CalculateLookAtDirection. Both Vector3s are 12 bytes, so
 * Win64 passes them BY ADDRESS; buffers are 4 floats wide either way so the
 * callee can never read past one. */
typedef unsigned long long (*AowlPact_U_PPPF)(void*, void*, void*, float, void*);
static double aowl_pact_look[2] = { 0.0, 0.0 };
static int32_t aowl_pact_lookat(void* fn, void* self,
                                double tx, double ty, double tz,
                                double px, double py, double pz,
                                double h) {
    float t[4], p[4], out[2];
    unsigned long long u;
    if (!fn || !self) return 0;
    if (tx != tx || ty != ty || tz != tz) return 0;
    if (px != px || py != py || pz != pz || h != h) return 0;
    if (tx > 1.0e9 || tx < -1.0e9 || ty > 1.0e9 || ty < -1.0e9 ||
        tz > 1.0e9 || tz < -1.0e9) return 0;
    if (px > 1.0e9 || px < -1.0e9 || py > 1.0e9 || py < -1.0e9 ||
        pz > 1.0e9 || pz < -1.0e9) return 0;
    t[0] = (float)tx; t[1] = (float)ty; t[2] = (float)tz; t[3] = 0.0f;
    p[0] = (float)px; p[1] = (float)py; p[2] = (float)pz; p[3] = 0.0f;
    u = ((AowlPact_U_PPPF)fn)(self, (void*)t, (void*)p, (float)h, NULL);
    memcpy(out, &u, sizeof(u));
    if (out[0] != out[0] || out[1] != out[1]) return 0;
    if (out[0] > 1.0e5f || out[0] < -1.0e5f) return 0;
    if (out[1] > 1.0e5f || out[1] < -1.0e5f) return 0;
    aowl_pact_look[0] = (double)out[0];
    aowl_pact_look[1] = (double)out[1];
    return 1;
}
static double aowl_pact_look_x(void) { return aowl_pact_look[0]; }
static double aowl_pact_look_y(void) { return aowl_pact_look[1]; }

/* INSTANCE, 0 args -> PACKED Vector2 in RAX.
 * MovementContext::get_Rotation -- the aim the game itself holds: x = yaw in
 * degrees, y = pitch. NOT an sret: 8 bytes come back in RAX, the same measured
 * Win64 shape as CalculateLookAtDirection's return above.
 *
 * REFUSES rather than reporting, on NaN and on a magnitude no angle can have.
 * 1e5 is deliberately loose -- the game does not normalise yaw into [0,360) at
 * every moment and a tight range would reject a legal reading -- but it is
 * still far tighter than "any float", so a half-torn-down context cannot feed a
 * plausible number into a rotation verdict. A refusal here makes the readback
 * INCONCLUSIVE at the caller, which is the third outcome and not a failure. */
static double aowl_pact_rot[2] = { 0.0, 0.0 };
static int32_t aowl_pact_get_v2(void* fn, void* self) {
    typedef unsigned long long (*AowlPact_U_P)(void*, void*);
    float out[2];
    unsigned long long u;
    if (!fn || !self) return 0;
    u = ((AowlPact_U_P)fn)(self, NULL);
    memcpy(out, &u, sizeof(u));
    if (out[0] != out[0] || out[1] != out[1]) return 0;
    if (out[0] > 1.0e5f || out[0] < -1.0e5f) return 0;
    if (out[1] > 1.0e5f || out[1] < -1.0e5f) return 0;
    aowl_pact_rot[0] = (double)out[0];
    aowl_pact_rot[1] = (double)out[1];
    return 1;
}
static double aowl_pact_rot_x(void) { return aowl_pact_rot[0]; }
static double aowl_pact_rot_y(void) { return aowl_pact_rot[1]; }

/* INSTANCE, (Ammo, Magazine, int, bool) -> Task<IResult>, IGNORED.
 * PlayerInventoryController::LoadMagazine. The Task is a managed object the
 * game already owns; we neither retain it nor look inside it, so nothing here
 * allocates and nothing needs a GC handle. Completion is observed by polling
 * Magazine::get_Count, never by inspecting this return value. */
typedef void* (*AowlPact_P_PPPIB)(void*, void*, void*, int32_t, int32_t, void*);
static int32_t aowl_pact_load_mag(void* fn, void* self, void* ammo, void* mag,
                                  int32_t count, int32_t ignoreRestrictions) {
    if (!fn || !self || !ammo || !mag) return 0;
    if (count <= 0 || count > 1000) return 0;   /* capped: no drum holds 1000 */
    ((AowlPact_P_PPPIB)fn)(self, ammo, mag, count, ignoreRestrictions ? 1 : 0, NULL);
    return 1;
}

/* INSTANCE, (Magazine, bool) -> Task<IResult>, IGNORED.
 * PlayerInventoryController::UnloadMagazine. */
typedef void* (*AowlPact_P_PPB)(void*, void*, int32_t, void*);
static int32_t aowl_pact_unload_mag(void* fn, void* self, void* mag,
                                    int32_t equipmentBlocked) {
    if (!fn || !self || !mag) return 0;
    ((AowlPact_P_PPB)fn)(self, mag, equipmentBlocked ? 1 : 0, NULL);
    return 1;
}

#endif /* AOWLSPT_PACT_H */
