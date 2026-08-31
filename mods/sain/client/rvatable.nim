## The SAIN member table, as DATA: a static RVA per row, or a stated refusal.
##
## ## Why this file exists
##
## Every member `client/live.nim` reaches was resolved BY NAME --
## `il2cpp_class_from_name` then `il2cpp_class_get_method_from_name`, through
## `resolveOn` -> `findOn` -> `findMethod`. On this build those two exports are
## TOKEN-GATED (fact #217): they take a trailing pointer to 32 bytes that no
## caller here passes, they `memcmp` it, and **on mismatch they do not return
## NULL -- they return a uniform random NON-ZERO uint64** from a per-thread
## MT19937-64. So a `!= nil` check PASSES and the first dereference kills the
## client. That is not a theory: this mod died inside exactly that call.
##
## `live.nim` therefore blocks the whole path at `ensure`, which means the mod
## is presently a no-op. This table is the way back: a **static RVA**, derived
## offline, called directly. A direct RVA call never touches the export ABI, so
## no gate applies to it.
##
## ## What is a row and what is a refusal
##
## A ROW is a member that resolved offline, unambiguously, to one address, whose
## first sixteen bytes are recorded here verbatim. It is byte-verified at bind
## time and refused out loud on a mismatch.
##
## A REFUSAL is a member that did NOT. There are five distinct reasons and they
## are kept distinct on purpose, because "this build does not have that name" and
## "this build has that name on a different class" want different reactions from
## whoever reads the log. **A refusal is never a fallback to the by-name path.**
## That is the whole point of the file: the fatal path is removed, not deferred.
##
## ## The honest scope
##
## This table covers 23 of SAIN's ~60 members. It does NOT make SAIN's combat
## brain work and nothing here claims it does. What it does is convert 23 silent
## kills into 23 direct calls and ~25 silent kills into ~25 named refusals.
##
## ## The dead-name archaeology (added; DATA ONLY, nothing new binds)
##
## The 31 refusals were re-examined offline against the same GameAssembly.dll.
## The headline result is that **"ABSENT FROM IMAGE" was the right measurement
## and the wrong conclusion**: 7 of the 12 dead names were never METHODS on this
## build, they are public FIELDS. `sainRvaFields` records those offsets, and the
## affected refusal `detail` strings now name the real post-1.0 owner instead of
## stopping at "no such method". `sainRvaCandidates` holds 4 members that
## resolved cleanly (unique RVA, real body, prologue captured) but are
## deliberately left UNBOUND.
##
## ## The field rows now have a consumer (this is the change)
##
## `sainRvaFieldRows` promotes NINE of those measured offsets into keyed,
## bindable rows -- pPhysical, phStamina, mcSprint, boMemory, memGoalEnemy,
## medFirstAid, medStims, medSurgery, wmReady -- and `live.nim` reads them
## through a guarded field path. Two ALREADY-BOUND RVA rows, `memUnderFire` and
## `surgHave`, become reachable for the first time as a consequence, because the
## receiver they needed was the thing that was missing. `stNormal` likewise:
## stamina is readable end to end.
##
## **Every one of these is a READ.** There is no write path and no drive call in
## the field mechanism at all -- `resolveFromRva` fills a read descriptor and
## only `callObj`/`callBoolOn` consume it, so "no drive call was wired" is a
## property of the shape rather than a promise about the contents. Every DRIVE
## call -- GoToPoint, Sprint, Stop, Shoot, and the medical `TryApply*` family --
## remains refused on purpose: a wrong pick there does not fail, it moves a bot.
##
## Three easy-looking wins are REFUSED on RECEIVER grounds, and that is the
## sharpest thing in this change: `wGrenades` (the call site holds a GameWorld,
## the field is BotWeaponManager's), `boAiming` (readable, but its only consumer
## matches the address against a hook that can never fire, so binding it would
## report success for a dead sensor), and `stimHave` (the receiver now arrives,
## but the base body's ownership of BotStimulators is unmeasured). A field read
## off the wrong object does not fault; it answers.
##
## The whole path stays behind `sainRvaTable`, which is DEFAULT OFF.
##
## ## Provenance
##
## Every RVA, signature, sharedness verdict and prologue below came from
##
##     python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \
##            .cache/global-metadata.dec.dat <member|type|shared|bytes> ...
##
## against GameAssembly.dll for install version 1.1.0.1.46777. Prologues are the
## verbatim `bytes <RVA> 16` output. Every one is in the `il2cpp` PE section and
## NONE is the universal `C2 00 00` empty-body stub -- a stub that passes a
## signature check is the worst case and it was checked for.
##
## ## Sharedness, and why it is recorded but not fatal here
##
## 28.3% of by-name lookups on this build land on an RVA more than one method
## owns. **CALLING a shared address is fine** -- it is correct compiled code for
## the receiver you pass, and the folding happened precisely because the bodies
## are identical. **DETOURING one is a write with unbounded blast radius.**
## Nothing in this file is ever detoured; `owners` is recorded so that a future
## reader cannot mistake one of these for a patch target.
##
## Two members were nevertheless REFUSED on sharedness grounds -- `wGrenades`
## (147 owners) and `boMemory` (341) -- because at that owner count the offline
## evidence that the address is the member we mean has effectively vanished.
##
## ## Virtual dispatch -- MEASURED, not assumed
##
## A bound direct call is NON-VIRTUAL. A row whose real runtime receiver
## OVERRIDES the member would dispatch to the wrong body. So the raw
## `Il2CppMethodDefinition.flags@28` (MethodAttributes) was read for all 23:
##
##   * 7 rows -- every `EFT.Player` getter -- are `0x09E6`, i.e.
##     VIRTUAL + **FINAL** + NEWSLOT. FINAL means no subclass may override, so a
##     non-virtual call to them is the call the game itself would make. The
##     concern in `live.nim`'s header (bots and observed players are different
##     `Player` subclasses) does NOT apply to a sealed slot.
##   * 16 rows are `0x0886`/`0x0086`, non-virtual outright.
##   * **ZERO rows are virtual-and-overridable.**
##
## The residual risk is a different one and it is stated here rather than
## papered over: these seven bodies are `EFT.Player`'s, so passing a receiver
## that is NOT an `EFT.Player` -- an `ObservedPlayerView`, which is a separate
## class with its own addresses -- reads `EFT.Player`'s field offsets off a
## foreign object. `live.nim` guards the receiver's readability; it cannot check
## its type without the reflection this file exists to avoid. Rows marked
## `needsPlayer` say so.

import aowlspt/fast

type
  SainRvaShape* = enum
    ## How the bound `Binding` is to be called, mirroring `live.nim`'s
    ## `CallShape`. Kept as a separate enum so this file stays pure data and
    ## does not have to import the module that imports it.
    srPlain              ## `fast`'s own convention: this, then declared args
    srStructReturn       ## slot 0 is a hidden return pointer, slot 1 is `this`
    srVectorArg          ## slot 0 is `this`, slot 1 is a pointer to the value

  SainRvaRow* = object
    key*: string         ## the `SainBindings` field this fills, e.g. "pIsAI"
    label*: string       ## "EFT.Player::get_IsAI", for the log
    rva*: int            ## VA minus imagebase 0x180000000
    prologue*: string    ## the 16 bytes at `rva`, uppercase hex, space-separated
    argc*: int32         ## DECLARED arguments (not native slots)
    ret*: FastKind
    shape*: SainRvaShape
    owners*: int         ## methods sharing this RVA; 1 == unique
    virt*: string        ## the measured MethodAttributes verdict
    needsPlayer*: bool   ## receiver must be an EFT.Player, not a look-alike

  SainRvaWhy* = enum
    ## The five reasons a member is not in the table. Distinct because they
    ## mean different things to a person reading the log after a client update.
    swAbsent             ## no such name in the image, at any arity
    swArity              ## the name exists, at an arity this mod does not call
    swOwner              ## the name exists, on a class this mod never holds
    swShared             ## the address has so many owners the evidence is gone
    swNotOffline         ## an instantiated generic; no offline layout exists
    swAmbiguous          ## several plausible owners; needs a live receiver

  SainRvaField* = object
    ## A MEASURED instance-field offset, from
    ## `Il2CppMetadataRegistration.fieldOffsets` via the same resolver that
    ## produced every RVA above, on the same GameAssembly.dll.
    ##
    ## This table exists because the single largest finding of the dead-name
    ## archaeology is that **most of SAIN's "absent" members were never methods
    ## on this build -- they are public FIELDS.** `get_Physical`, `get_Stamina`,
    ## `get_Memory`, `get_FirstAid`, `get_Stimulators`, `get_SurgicalKit` and
    ## `get_Grenades` all have a real, uniquely-named backing field at a fixed
    ## offset. A raw static-offset read is the FIRST item of the host toolkit,
    ## so every one of those capabilities is recoverable -- by reading, not by
    ## calling.
    ##
    ## THIS TABLE IS STILL PURE ARCHAEOLOGY -- it is keyless and nothing binds
    ## from it. Nine of its offsets have since been PROMOTED into
    ## `sainRvaFieldRows` below, which is the keyed, bindable, consumed table.
    ## The two are kept apart on purpose: a measurement is not a binding, and
    ## collapsing them would make "measured" and "wired" the same claim again.
    ## Three offsets here are deliberately NOT promoted (Grenades, IsReady's
    ## sibling AimingManager, GetPlayer) and the refusals say why for each.
    owner*: string       ## the declaring type, exactly as metadata names it
    field*: string       ## the field name, exactly as metadata names it
    off*: int            ## byte offset from the object base
    ftype*: string       ## the field's declared type
    note*: string

  SainRvaFieldRow* = object
    ## A KEYED, BINDABLE field read -- the consumer `SainRvaField` never had.
    ##
    ## `SainRvaField` above is archaeology: a measured offset with no key and no
    ## call site, recorded so nobody re-derives it. This type is the other half.
    ## It carries a `SainBindings` key, so `tools/idxbind.py` treats it exactly
    ## like a `SainRvaRow` -- a key that is both a field row and a refusal fails
    ## the build, and a field row no `keyed(...)` site consumes fails it too.
    ##
    ## WHY A SEPARATE PATH AND NOT AN RVA ROW. There is no function to call and
    ## therefore no prologue to verify. The verification that replaces it is
    ## narrower and is stated per row: the offset came from
    ## `Il2CppMetadataRegistration.fieldOffsets`, and five of the offsets in this
    ## family are independently corroborated by prologues already in this file
    ## (`get_Medecine` compiles to `mov rax,[rcx+0x2C8]`, and `Medecine` is
    ## measured at 0x2C8). A field read cannot dispatch to the wrong body,
    ## cannot be shared with 146 other methods, and cannot be detoured out from
    ## under us. What it CAN do is read the right offset off the WRONG OBJECT,
    ## and that is the entire risk surface:
    ##
    ## **`recv` is load-bearing.** It names the type the call site must already
    ## be holding, and every row here was checked against the receiver its
    ## `live.nim` call site actually passes. Three members that would otherwise
    ## have been easy wins are REFUSED on exactly this ground -- `wGrenades`
    ## (the site passes a GameWorld, the field is BotWeaponManager's) among
    ## them. Readability is not type identity, and this build gives us no way to
    ## ask; the chain is the proof, so every row is reachable only by walking
    ## from a receiver another bound row or field row produced.
    key*: string         ## the `SainBindings` field this fills
    label*: string       ## "EFT.Player.Physical@0x9D8", for the log
    recv*: string        ## the type the receiver MUST be; see above
    off*: int            ## byte offset from the object base
    kind*: FastKind      ## fkPtr for a reference, fkBool for a bool, ...
    needsPlayer*: bool   ## receiver must be an EFT.Player, not a look-alike
    unityObj*: bool      ## receiver is a UnityEngine.Object: check m_CachedPtr
    why*: string         ## the measurement and the receiver argument

  SainRvaCandidate* = object
    ## A member that RESOLVED cleanly offline but is deliberately NOT bound.
    ##
    ## Deliberately NOT a `SainRvaRow`. The `idxbind` build gate treats every
    ## `SainRvaRow` literal in this file as a bindable row and fails the build
    ## if its key is also refused, or if no `keyed(...)` site in `live.nim`
    ## consumes it. That gate is correct and it caught this table on its first
    ## build -- an unreferenced row DOES look converted and is not. A separate
    ## type keeps "measured" and "bound" from being the same claim.
    symbol*: string      ## owner::member
    rva*: int
    prologue*: string    ## the 16 bytes at `rva`, verbatim
    argc*: int32
    owners*: int         ## 1 == unique
    virt*: string
    why*: string         ## why it is measured but not bound

  SainRvaRefusal* = object
    key*: string
    symbol*: string      ## what `bindAll` asks for, verbatim
    why*: SainRvaWhy
    detail*: string      ## the measurement, not an opinion

proc emptyRvaRow*(): SainRvaRow =
  ## An explicitly zeroed row. Nimony will not let a `var` of an object type be
  ## passed as a `var` out-parameter unless it can prove initialisation, and
  ## that rule is worth keeping rather than working around: the out-parameter
  ## is only meaningful when the lookup returned true, and a caller that used
  ## it anyway would otherwise read whatever was on the stack.
  SainRvaRow(key: "", label: "", rva: 0, prologue: "", argc: 0'i32,
             ret: fkNone, shape: srPlain, owners: 0, virt: "",
             needsPlayer: false)

proc emptyRvaRefusal*(): SainRvaRefusal =
  SainRvaRefusal(key: "", symbol: "", why: swAbsent, detail: "")

proc emptyRvaField*(): SainRvaField =
  SainRvaField(owner: "", field: "", off: 0, ftype: "", note: "")

proc whyText*(w: SainRvaWhy): string =
  case w
  of swAbsent:     "ABSENT FROM IMAGE"
  of swArity:      "WRONG ARITY"
  of swOwner:      "WRONG OWNER"
  of swShared:     "REFUSED: SHARED RVA"
  of swNotOffline: "NOT RESOLVABLE OFFLINE"
  of swAmbiguous:  "AMBIGUOUS WITHOUT A LIVE RECEIVER"

const
  SainRvaScope* = "GameAssembly.dll 1.1.0.1.46777"
    ## Stamped into every log line this table produces. A Tarkov update makes
    ## every row here stale, and the prologue byte-compare is what turns that
    ## staleness into a refusal instead of a jump into an unrelated function --
    ## but only a human reading this string knows to re-derive them.

proc sainRvaRows*(): seq[SainRvaRow] =
  ## The 23 members that resolved unambiguously. Data only.
  result = @[]

  # --- EFT.Player. All seven are VIRTUAL+FINAL+NEWSLOT (flags 0x09E6): sealed
  # interface implementations, so a direct non-virtual call is correct, and all
  # seven require a real `EFT.Player` receiver.
  result.add SainRvaRow(key: "pIsAI", label: "EFT.Player::get_IsAI",
    rva: 0x726890, prologue: "40 53 48 83 EC 20 80 3D AA 18 99 06 00 48 8B D9",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0x11 -- FINAL, cannot be overridden",
    needsPlayer: true)
  result.add SainRvaRow(key: "pProfileId", label: "EFT.Player::get_ProfileId",
    rva: 0x71F9E0, prologue: "48 83 EC 28 48 8B 81 C0 09 00 00 48 85 C0 74 09",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0x13 -- FINAL, cannot be overridden",
    needsPlayer: true)
  result.add SainRvaRow(key: "pAIData", label: "EFT.Player::get_AIData",
    rva: 0x7267B0, prologue: "48 8B 81 00 0A 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0xF -- FINAL, cannot be overridden",
    needsPlayer: true)
  result.add SainRvaRow(key: "pHealth",
    label: "EFT.Player::get_HealthController",
    rva: 0x727E40, prologue: "48 8B 81 20 0A 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0xD -- FINAL, cannot be overridden",
    needsPlayer: true)
  result.add SainRvaRow(key: "pMovement",
    label: "EFT.Player::get_MovementContext",
    rva: 0x690D20, prologue: "48 8B 41 60 C3 CC CC CC CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 136,
    virt: "non-virtual body; folded with 135 other one-instruction getters " &
          "(mov rax,[rcx+0x60]; ret). Calling it is correct for any receiver " &
          "whose field at 0x60 is the one meant -- which for an EFT.Player IS " &
          "MovementContext. NEVER detour this address.",
    needsPlayer: true)
  # Vector3 return: 12 bytes, not a register class, so Win64 returns it
  # through a hidden pointer the CALLER supplies. Slot 0 is that buffer and
  # slot 1 is `this` -- note the prologue's `48 8B 82 ...` reading through
  # RDX, which is `this` in the second slot and is the direct confirmation
  # of the shape rather than an assumption about it.
  result.add SainRvaRow(key: "pPosition", label: "EFT.Player::get_Position",
    rva: 0x6F32C0, prologue: "40 53 48 83 EC 30 48 8B 82 40 0B 00 00 48 8B D9",
    argc: 0'i32, ret: fkPtr, shape: srStructReturn, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0xA -- FINAL, cannot be overridden",
    needsPlayer: true)
  # Same shape, same evidence: `48 8B 42 60` is a load through RDX.
  result.add SainRvaRow(key: "pLookDir", label: "EFT.Player::get_LookDirection",
    rva: 0x6F8060, prologue: "48 83 EC 28 48 8B 42 60 48 85 C0 74 1D F2 0F 10",
    argc: 0'i32, ret: fkPtr, shape: srStructReturn, owners: 1,
    virt: "VIRTUAL+FINAL+NEWSLOT slot 0x9 -- FINAL, cannot be overridden",
    needsPlayer: true)

  # --- Stamina
  result.add SainRvaRow(key: "stNormal", label: "Stamina::get_NormalValue",
    rva: 0x1CB0720, prologue: "40 53 48 83 EC 30 80 3D 7E FD 40 05 00 48 8B D9",
    argc: 0'i32, ret: fkF32, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)

  # --- EFT.BotOwner components
  result.add SainRvaRow(key: "boWeapon",
    label: "EFT.BotOwner::get_WeaponManager",
    rva: 0x80F040, prologue: "48 8B 81 08 03 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)
  result.add SainRvaRow(key: "boMover", label: "EFT.BotOwner::get_Mover",
    rva: 0x80F920, prologue: "48 8B 81 D0 03 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 5,
    virt: "flags 0x0886 -- non-virtual; folded with 4 UIElements getters at " &
          "the same field offset. NEVER detour.", needsPlayer: false)
  result.add SainRvaRow(key: "boSteering", label: "EFT.BotOwner::get_Steering",
    rva: 0x80D8E0, prologue: "48 8B 81 48 01 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 13,
    virt: "flags 0x0886 -- non-virtual; folded with 12 others. NEVER detour.",
    needsPlayer: false)
  result.add SainRvaRow(key: "boShoot", label: "EFT.BotOwner::get_ShootData",
    rva: 0x80E8D0, prologue: "48 8B 81 80 02 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 2,
    virt: "flags 0x0886 -- non-virtual; folded with BetterAudio::" &
          "get_UpdateSystem. NEVER detour.", needsPlayer: false)
  result.add SainRvaRow(key: "boMedecine", label: "EFT.BotOwner::get_Medecine",
    rva: 0x80ECC0, prologue: "48 8B 81 C8 02 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)

  # --- EFT.BotMemory
  result.add SainRvaRow(key: "memUnderFire",
    label: "EFT.BotMemory::get_IsUnderFire",
    rva: 0x24DEEC0, prologue: "48 83 EC 38 48 8B 05 35 5B BF 04 0F 29 74 24 20",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)

  # --- EnemyInfo
  result.add SainRvaRow(key: "enPerson", label: "EnemyInfo::get_Person",
    rva: 0x66E6E0, prologue: "48 8B 81 98 00 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 79,
    virt: "flags 0x0886 -- non-virtual; folded with 78 other getters at field " &
          "offset 0x98. NEVER detour.", needsPlayer: false)
  result.add SainRvaRow(key: "enPosition", label: "EnemyInfo::get_CurrPosition",
    rva: 0x1A02CB0, prologue: "48 89 5C 24 08 57 48 83 EC 30 80 3D E5 C8 6B 05",
    argc: 0'i32, ret: fkPtr, shape: srStructReturn, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)

  # --- BotWeaponManager / BotReload
  result.add SainRvaRow(key: "wmHaveBullets",
    label: "BotWeaponManager::get_HaveBullets",
    rva: 0xD3B180, prologue: "40 53 48 83 EC 20 48 8B 41 30 48 8B D9 48 85 C0",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)
  result.add SainRvaRow(key: "wmReload",
    label: "BotWeaponManager::get_Reload",
    rva: 0xD3AF70, prologue: "48 83 EC 28 48 8B 41 30 48 85 C0 74 09 48 8B 40",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 2,
    virt: "flags 0x0886 -- non-virtual; folded with System.Xml." &
          "XsdCachingReader::get_NamespaceURI. NEVER detour.",
    needsPlayer: false)
  # Declared `bool TryReload()`. `live.nim` drives it through `callVoidOn`,
  # which ignores RAX; that is harmless, and it is stated because a reader
  # comparing this row to the call site would otherwise see a mismatch.
  result.add SainRvaRow(key: "rlTryReload", label: "BotReload::TryReload",
    rva: 0xBB44A0, prologue: "40 53 48 83 EC 30 33 C0 48 8B D9 48 89 44 24 40",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0086 -- non-virtual", needsPlayer: false)
  result.add SainRvaRow(key: "rlMaxBullets",
    label: "BotReload::get_MaxBulletCount",
    rva: 0xBB1420, prologue: "40 53 48 83 EC 20 80 3D 7D 87 50 06 00 48 8B D9",
    argc: 0'i32, ret: fkI32, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)

  # --- Medicine
  result.add SainRvaRow(key: "surgHave", label: "BotSurgicalKit::get_HaveWork",
    rva: 0x1A24F20, prologue: "80 79 51 00 75 03 32 C0 C3 48 83 79 48 00 0F 97",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual", needsPlayer: false)
  result.add SainRvaRow(key: "faHave",
    label: "BotAbstractMedsToPart::get_HaveSmth2Use",
    rva: 0x8D1B80, prologue: "48 83 79 48 00 0F 97 C0 C3 CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 3,
    virt: "flags 0x0886 -- non-virtual, declared on the ABSTRACT base, so " &
          "every derived meds component inherits this exact body; folded with " &
          "2 unrelated getters. NEVER detour.", needsPlayer: false)

  # --- Driving. The ONE driving call that resolved unambiguously.
  # `void LookToPoint(Vector3 point)`, arity 1, DERIVED not inferred:
  # `il2cpp_resolve.py member LookToPoint` prints the full signature, and the
  # arity-2 overload `LookToPoint(Vector3, float)` is a DIFFERENT address
  # (0x1a3b760) which this row therefore cannot be confused with. The 12-byte
  # Vector3 goes by hidden pointer in slot 1, `this` in slot 0.
  result.add SainRvaRow(key: "stLookTo", label: "BotSteering::LookToPoint",
    rva: 0x1A3B690, prologue: "48 83 EC 28 48 8B 41 10 48 85 C0 74 3C 48 8B 40",
    argc: 1'i32, ret: fkVoid, shape: srVectorArg, owners: 1,
    virt: "flags 0x0086 -- non-virtual", needsPlayer: false)

proc sainRvaFields*(): seq[SainRvaField] =
  ## The reach-by-field table. MEASURED offline; see `SainRvaField`.
  ##
  ## Independent cross-check that these offsets are the right table: five of
  ## them are visible in prologues ALREADY in this file. `BotOwner::get_Medecine`
  ## is `48 8B 81 C8 02 00 00` = `[rcx+0x2C8]`, and `Medecine` is measured at
  ## 0x2C8 below. Same for WeaponManager 0x308, Mover 0x3D0, Steering 0x148 and
  ## ShootData 0x280. The field table and the RVA table agree without having
  ## been derived from each other.
  result = @[]

  # --- Physical / stamina. `get_Physical` and `get_Stamina` are ABSENT as
  # METHODS because on this build they were never properties. Two field hops
  # from a live EFT.Player land on the `Stamina` object that the ALREADY-BOUND
  # `Stamina::get_NormalValue` @0x1CB0720 takes as its receiver.
  result.add SainRvaField(owner: "EFT.Player", field: "Physical", off: 0x9D8,
    ftype: "PhysicalBase",
    note: "public instance field. THE replacement for get_Physical. Receiver " &
          "must be a real EFT.Player (same hazard as every needsPlayer row).")
  result.add SainRvaField(owner: "PhysicalBase", field: "Stamina", off: 0x68,
    ftype: "Stamina",
    note: "public instance field. THE replacement for get_Stamina. Siblings " &
          "HandsStamina@0x70 and Oxygen@0x78 are the same type.")
  result.add SainRvaField(owner: "PhysicalBase", field: "_sprinting",
    off: 0xD9, ftype: "bool",
    note: "reads sprint state without the ambiguous get_IsSprintEnabled")

  # --- Bot memory. `get_Memory` is not merely on the wrong owner: BotOwner
  # has no such property at all. It is a field.
  result.add SainRvaField(owner: "EFT.BotOwner", field: "Memory", off: 0x60,
    ftype: "BotMemory",
    note: "public instance field. THE replacement for BotOwner::get_Memory. " &
          "Its value is the receiver the already-bound BotMemory::" &
          "get_IsUnderFire @0x24DEEC0 wants.")
  result.add SainRvaField(owner: "EFT.BotMemory", field: "_goalEnemy",
    off: 0x60, ftype: "EnemyInfo",
    note: "THE replacement for BotMemory::get_GoalEnemy. Feeds the two bound " &
          "EnemyInfo rows (enPerson, enPosition).")
  result.add SainRvaField(owner: "EFT.BotOwner", field: "GetPlayer", off: 0x418,
    ftype: "Player",
    note: "<GetPlayer>k__BackingField. BotOwner -> the EFT.Player every " &
          "needsPlayer row requires, without a type check.")

  # --- Medical. All three medical components are FIELDS on BotMedecine, whose
  # own getter (BotOwner::get_Medecine @0x80ECC0, UNIQUE) is already bound.
  result.add SainRvaField(owner: "BotMedecine", field: "FirstAid", off: 0x18,
    ftype: "BotFirstAid", note: "THE replacement for get_FirstAid")
  result.add SainRvaField(owner: "BotMedecine", field: "Stimulators",
    off: 0x20, ftype: "BotStimulators",
    note: "THE replacement for get_Stimulators")
  result.add SainRvaField(owner: "BotMedecine", field: "SurgicalKit",
    off: 0x28, ftype: "BotSurgicalKit",
    note: "THE replacement for get_SurgicalKit. Its value is the receiver the " &
          "already-bound BotSurgicalKit::get_HaveWork @0x1A24F20 wants.")

  # --- Grenades. `get_Grenades` DOES exist on BotWeaponManager, but its RVA
  # (0x690CB0) is folded 147 ways -- it is the one-instruction body
  # `mov rax,[rcx+0x58]; ret`. Reading the field IS that body, with no
  # sharedness question to answer at all.
  result.add SainRvaField(owner: "BotWeaponManager", field: "Grenades",
    off: 0x58, ftype: "BotGrenadeController",
    note: "<Grenades>k__BackingField. Reading it is byte-identical to what " &
          "the 147-owner getter at 0x690CB0 compiles to.")
  result.add SainRvaField(owner: "BotWeaponManager", field: "IsReady",
    off: 0x80, ftype: "bool",
    note: "<IsReady>k__BackingField. Resolves the wmReady AMBIGUOUS refusal " &
          "without needing to pick among same-named getters.")

  # --- Aim. See `sainRvaCandidates` for the call-shaped route.
  result.add SainRvaField(owner: "EFT.BotOwner", field: "AimingManager",
    off: 0x290, ftype: "AimingManager",
    note: "<AimingManager>k__BackingField; the post-1.0 home of aim state")

proc emptyRvaFieldRow*(): SainRvaFieldRow =
  SainRvaFieldRow(key: "", label: "", recv: "", off: 0, kind: fkNone,
                  needsPlayer: false, unityObj: false, why: "")

proc sainRvaFieldRows*(): seq[SainRvaFieldRow] =
  ## The nine sensors that move from REFUSED to BOUND by reading a field.
  ##
  ## Every offset here is one of `sainRvaFields`' measurements, promoted to a
  ## key. Nothing new was derived; what is new is the `recv` column and the
  ## argument in each `why` for why the call site's receiver is that type.
  ##
  ## READ-ONLY BY CONSTRUCTION. There is no write path for a field row anywhere
  ## in `live.nim`; `resolveFromRva` fills a read descriptor and the only
  ## consumers are `callObj` and `callBoolOn`. No drive call is expressible
  ## here, which is a stronger statement than "none is present".
  result = @[]

  # --- Physical / stamina. `bridge.readStamina` holds `l.player`, and
  # `l.player` is what `pIsAI`/`pPosition` (both needsPlayer rows) are already
  # called on -- so if the receiver were not an EFT.Player the seven bound
  # EFT.Player rows would already be reading garbage. Same receiver, same
  # standing.
  result.add SainRvaFieldRow(key: "pPhysical", label: "EFT.Player.Physical@0x9D8",
    recv: "EFT.Player", off: 0x9D8, kind: fkPtr, needsPlayer: true,
    unityObj: true,
    why: "public instance field of type PhysicalBase; THE post-1.0 replacement " &
         "for the ABSENT get_Physical. Receiver at the call site is " &
         "`BotLive.player`, the same object the seven needsPlayer RVA rows " &
         "already take. EFT.Player derives from MonoBehaviour, so liveness is " &
         "checked via m_CachedPtr before the chain continues")
  result.add SainRvaFieldRow(key: "phStamina",
    label: "PhysicalBase.Stamina@0x68",
    recv: "PhysicalBase", off: 0x68, kind: fkPtr, needsPlayer: false,
    unityObj: false,
    why: "public instance field; THE replacement for the ABSENT get_Stamina. " &
         "Receiver is whatever pPhysical returned, so the type is established " &
         "by the walk rather than assumed. Its value is exactly the receiver " &
         "the ALREADY-BOUND Stamina::get_NormalValue @0x1CB0720 wants, which " &
         "is what makes stamina readable END TO END for the first time. " &
         "Siblings HandsStamina@0x70 and Oxygen@0x78 are the same type, so an " &
         "off-by-8 here would read a plausible number -- the offset is taken " &
         "verbatim from fieldOffsets, never counted by hand")
  # `mcSprint` is bound to PhysicalBase._sprinting, NOT to a MovementContext.
  # Its former call sites passed a MovementContext, which is a DIFFERENT object
  # with different offsets; those two sites were changed to walk through
  # pPhysical instead. That is the receiver rule applied, not worked around.
  result.add SainRvaFieldRow(key: "mcSprint",
    label: "PhysicalBase._sprinting@0xD9",
    recv: "PhysicalBase", off: 0xD9, kind: fkBool, needsPlayer: false,
    unityObj: false,
    why: "a bool field. Replaces the AMBIGUOUS get_IsSprintEnabled, which " &
         "could not be resolved without a live MovementContext. Receiver is " &
         "the PhysicalBase pPhysical returned -- the two call sites in " &
         "bridge.nim and driver.nim were CHANGED from a MovementContext " &
         "receiver to this one, because reading 0xD9 off a MovementContext " &
         "would be a foreign read that faults nowhere and answers wrongly")

  # --- Bot memory. Receiver is `BotLive.owner`, the same object the five bound
  # `EFT.BotOwner::get_*` rows are called on.
  result.add SainRvaFieldRow(key: "boMemory", label: "EFT.BotOwner.Memory@0x60",
    recv: "EFT.BotOwner", off: 0x60, kind: fkPtr, needsPlayer: false,
    unityObj: true,
    why: "public instance field of type BotMemory. The NAME get_Memory is " &
         "refusable and was refused: the only one in the image is " &
         "MemoryMetricCollector::get_Memory, a profiler counter on a " &
         "341-owner RVA. The field is not that member under another name, it " &
         "is the bot's memory. Its value is the receiver the ALREADY-BOUND " &
         "BotMemory::get_IsUnderFire @0x24DEEC0 wants, so memUnderFire -- a " &
         "row that has been bound and unreachable -- becomes readable")
  result.add SainRvaFieldRow(key: "memGoalEnemy",
    label: "EFT.BotMemory._goalEnemy@0x60",
    recv: "EFT.BotMemory", off: 0x60, kind: fkPtr, needsPlayer: false,
    unityObj: false,
    why: "replaces the AMBIGUOUS get_GoalEnemy. Receiver is what boMemory " &
         "returned. Feeds the two bound EnemyInfo rows (enPerson, enPosition). " &
         "NOTE the coincidence that BotOwner.Memory and BotMemory._goalEnemy " &
         "are BOTH at 0x60: they are different types and the walk is what " &
         "keeps them apart, so a dropped hop would read an EnemyInfo off a " &
         "BotOwner and not fault. The chain is validated hop by hop for " &
         "exactly this reason")

  # --- Medical. Receiver is the BotMedecine that the ALREADY-BOUND, UNIQUE
  # BotOwner::get_Medecine @0x80ECC0 returned -- the strongest receiver
  # provenance in this table, since it comes from a one-owner getter.
  result.add SainRvaFieldRow(key: "medFirstAid",
    label: "BotMedecine.FirstAid@0x18",
    recv: "BotMedecine", off: 0x18, kind: fkPtr, needsPlayer: false,
    unityObj: false,
    why: "public field of type BotFirstAid; replaces the ABSENT get_FirstAid. " &
         "Its value is the receiver the already-bound faHave " &
         "(BotAbstractMedsToPart::get_HaveSmth2Use @0x8D1B80) wants")
  result.add SainRvaFieldRow(key: "medStims",
    label: "BotMedecine.Stimulators@0x20",
    recv: "BotMedecine", off: 0x20, kind: fkPtr, needsPlayer: false,
    unityObj: false,
    why: "public field of type BotStimulators; replaces the ABSENT " &
         "get_Stimulators. Reaching the component is NOT the same as reading " &
         "it: stimHave stays refused, see its entry")
  result.add SainRvaFieldRow(key: "medSurgery",
    label: "BotMedecine.SurgicalKit@0x28",
    recv: "BotMedecine", off: 0x28, kind: fkPtr, needsPlayer: false,
    unityObj: false,
    why: "public field of type BotSurgicalKit; replaces the ABSENT " &
         "get_SurgicalKit. Its value is the receiver the already-bound " &
         "BotSurgicalKit::get_HaveWork @0x1A24F20 wants, so surgHave -- bound " &
         "and unreachable until now -- becomes readable")

  # --- Weapon readiness.
  result.add SainRvaFieldRow(key: "wmReady",
    label: "BotWeaponManager.<IsReady>@0x80",
    recv: "BotWeaponManager", off: 0x80, kind: fkBool, needsPlayer: false,
    unityObj: false,
    why: "<IsReady>k__BackingField. Resolves the AMBIGUOUS get_IsReady without " &
         "picking among same-named getters on other classes -- the ambiguity " &
         "was never about the field, only about the NAME. Receiver is what " &
         "the bound, UNIQUE BotOwner::get_WeaponManager @0x80F040 returned")

proc findRvaFieldRow*(rows: seq[SainRvaFieldRow]; key: string;
                      hit: var SainRvaFieldRow): bool =
  ## Linear over a literal table, once per member per session.
  result = false
  var i = 0
  while i < rows.len:
    if rows[i].key == key:
      hit = rows[i]
      return true
    inc i

proc emptyRvaCandidate*(): SainRvaCandidate =
  SainRvaCandidate(symbol: "", rva: 0, prologue: "", argc: 0'i32, owners: 0,
                   virt: "", why: "")

proc sainRvaCandidates*(): seq[SainRvaCandidate] =
  ## Rows that RESOLVED cleanly -- unique RVA, real body in the `il2cpp`
  ## section, prologue captured -- but that are deliberately NOT bound, so the
  ## mod's runtime behaviour is unchanged by this file's archaeology.
  ##
  ## They are here because the measurement is the expensive part and it is
  ## done. Promoting one into `sainRvaRows` is a one-line move plus a matching
  ## deletion from `sainRvaRefusals` -- and a decision a human should make,
  ## because binding a key changes what `live.nim` does.
  result = @[]

  result.add SainRvaCandidate(symbol: "EFT.BotOwner::get_AimingManager",
    rva: 0x80E9B0, prologue: "48 8B 81 90 02 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, owners: 1, virt: "flags 0x0886 -- non-virtual",
    why: "the post-1.0 replacement for the ABSENT get_AimingData, but it " &
         "returns an AimingManager, not the AimingData shape sain.nim's aim " &
         "postfix was written against. Binding the boAiming key to a " &
         "different-shaped object is a change no offline evidence can check")
  result.add SainRvaCandidate(symbol: "AimingManager::get_CurrentAiming",
    rva: 0x23D5B60, prologue: "40 53 48 83 EC 20 80 3D EF CC CE 04 00 48 8B D9",
    argc: 0'i32, owners: 1, virt: "flags 0x0886 -- non-virtual",
    why: "second hop of the aim route; no key in live.nim asks for it yet")
  result.add SainRvaCandidate(symbol: "Aiming::get_IsReady",
    rva: 0x1AD48C0, prologue: "40 53 48 83 EC 30 80 3D BB B0 5E 05 00 48 8B D9",
    argc: 0'i32, owners: 1,
    virt: "flags 0x0886 -- non-virtual",
    why: "third hop of the aim route. The receiver must be an `Aiming` -- i.e. " &
         "exactly what get_CurrentAiming returned. The declared return type " &
         "there is the INTERFACE IBotAiming, which has other implementors " &
         "(UnderbarrelLauncherBotAiming does NOT derive from Aiming, MEASURED " &
         "on the parent chain), so this is the one hop in the route that " &
         "needs a live type check we cannot do")
  result.add SainRvaCandidate(symbol: "BotSurgicalKit::ShallStartUse",
    rva: 0x1A24F40, prologue: "40 53 48 83 EC 30 48 8B 05 B3 FA 6A 05 48 8B D9",
    argc: 0'i32, owners: 1, virt: "flags 0x0086 -- non-virtual",
    why: "a safe arity-0 bool READ next to the refused surgery drive call; " &
         "no key in live.nim asks for it yet")

proc sainRvaRefusals*(): seq[SainRvaRefusal] =
  ## Every member `bindAll` asks for that this table will NOT bind, with the
  ## measurement that decided it. Each of these produces a WARN naming the
  ## symbol. None of them falls back to the by-name path.
  result = @[]

  # --- ABSENT: no such name in the image, at any arity.
  #
  # `pPhysical`, `phStamina`, `medFirstAid`, `medStims` and `medSurgery` USED to
  # be refused here. They are now BOUND, as field rows, in `sainRvaFieldRows`.
  # None of them became a method; the members are still absent. What changed is
  # that the read no longer needs one.
  result.add SainRvaRefusal(key: "boAiming", symbol: "get_AimingData",
    why: swAbsent, detail: "no method named get_AimingData exists at any " &
    "arity. The typed aim postfix in sain.nim therefore has no way to " &
    "attribute a reading to a bot. The post-1.0 owner of aim state is " &
    "AimingManager: BotOwner::get_AimingManager @0x80E9B0 (UNIQUE, " &
    "non-virtual) -> AimingManager::get_CurrentAiming @0x23D5B60 (UNIQUE) -> " &
    "an `Aiming`, whose get_IsReady is @0x1AD48C0. All three are measured and " &
    "sit in sainRvaCandidates, deliberately unbound. The class literally " &
    "named BotAimingData is NOT it: no field or getter anywhere in the image " &
    "returns one, so it is unreachable and is not the replacement. " &
    "DELIBERATELY STILL REFUSED although the read is now trivially available: " &
    "EFT.BotOwner.<AimingManager> is a FIELD at 0x290 and the call site holds " &
    "a BotOwner, so binding it would succeed and return a plausible pointer. " &
    "It is refused because of what the ONLY consumer does with it -- " &
    "driver.nim caches the returned ADDRESS as `aimKey` and matches it against " &
    "readings the typed postfix on EFT.BotAimingData::get_IsReady deposits. " &
    "That hook is on a class nothing in the image ever returns, so it never " &
    "fires and the key can never match. Binding this would therefore report a " &
    "successful read for a sensor that is still dead: a check that cannot " &
    "fail (CLAUDE.md 9b). Re-point the hook first, then bind")

  # --- WRONG ARITY: the name is here, at an arity this mod never calls.
  result.add SainRvaRefusal(key: "hcBodyPart", symbol: "GetBodyPartHealth",
    why: swArity, detail: "declared arity 2 on EVERY owner; this mod calls it " &
    "at arity 1. A member that exists only at an arity you never call is a " &
    "member you can never bind. The real signature is DERIVED, not inferred: " &
    "ValueStruct GetBodyPartHealth(EBodyPart bodyPart, bool rounded). The " &
    "two bindable owners are ObservedPlayerHealthController @0x1E19290 and " &
    "EFT.HealthInfoAdapter @0x8E4930, both UNIQUE, both flags 0x01E6 = " &
    "VIRTUAL+FINAL+NEWSLOT so a direct non-virtual call is what the game " &
    "itself makes. RECOVERABLE ONLY IF the call site is changed to arity 2 " &
    "AND a struct-return shape: ValueStruct is a value type, so Win64 returns " &
    "it through a caller-supplied hidden pointer. That is a call-site change, " &
    "not a table change, so it is left refused")
  result.add SainRvaRefusal(key: "faApply",
    symbol: "BotFirstAid::TryApplyToCurrentPart", why: swArity,
    detail: "declared arity 2, DERIVED: void TryApplyToCurrentPart(" &
    "Nullable<int> varianAnim, Action callback) @0x1A20740, UNIQUE, flags " &
    "0x0086 non-virtual. Bindable in principle; NOT bound because it is a " &
    "DRIVE call -- it makes the bot heal -- and because passing a null " &
    "managed Action for the callback is unverified")
  result.add SainRvaRefusal(key: "stimApply", symbol: "BotStimulators::TryApply",
    why: swArity, detail: "declared arity 3, DERIVED: void TryApply(bool " &
    "noCheckDelay, Nullable<int> animVarian, Action<bool> callback) " &
    "@0x1A245E0, UNIQUE, flags 0x0086 non-virtual. Same reason as faApply: a " &
    "drive call with an unverified null-delegate argument")
  result.add SainRvaRefusal(key: "surgApply",
    symbol: "BotSurgicalKit::TryApplyToCurrentPart", why: swArity,
    detail: "the only TryApplyToCurrentPart at a usable owner is arity 2; " &
    "this mod calls it at arity 0. MEASURED: BotSurgicalKit has NO method of " &
    "that name at all -- its equivalent is ApplyToCurrentPart(Action " &
    "callbackEndUse) @0x1A252F0, arity 1, UNIQUE, non-virtual. A drive call, " &
    "left refused. The safe READ next to it is ShallStartUse() @0x1A24F40, " &
    "arity 0, bool, UNIQUE -- in sainRvaCandidates")

  # --- WRONG OWNER / SHARED beyond evidence.
  #
  # `boMemory` used to be refused here on the strength of the NAME being wrong.
  # That measurement still stands and the name is still refused; the KEY is now
  # bound as a field row instead, which is a different route to the same datum.
  result.add SainRvaRefusal(key: "wGrenades", symbol: "get_Grenades",
    why: swOwner, detail: "REFUSED ON RECEIVER GROUNDS, which is a stronger " &
    "and more specific reason than the sharedness this row used to cite. " &
    "MEASURED: BotWeaponManager.<Grenades>k__BackingField is at 0x58 and the " &
    "147-owner body at 0x690CB0 is literally `mov rax,[rcx+0x58]; ret`, so " &
    "the sharedness question is moot and the field read is available. It is " &
    "NOT taken, because live.nim's `grenadeList` passes the GAMEWORLD as the " &
    "receiver, not a BotWeaponManager. Reading offset 0x58 off a GameWorld " &
    "would be readable, would not fault, and would answer with whatever " &
    "GameWorld keeps there -- a foreign read is the one failure mode a field " &
    "row has, and this is it. Consequence unchanged: cdAvoidGrenade stays " &
    "unreachable. RECOVERABLE only by changing the call site to walk " &
    "BotOwner -> WeaponManager -> Grenades, which is a call-site decision")

  # --- NOT RESOLVABLE OFFLINE: instantiated generics.
  result.add SainRvaRefusal(key: "listCount", symbol: "List<Player>::get_Count",
    why: swNotOffline, detail: "263 arity-matching owners of get_Count. This " &
    "is a List<T> INSTANTIATION: IL2CPP writes an all-zero fieldOffsets array " &
    "for uninstantiated generic definitions and every Il2CppGenericClass in " &
    "the file has a null cached_class, so no instantiated layout is reachable " &
    "offline. It must be BORROWED from a live object, and this table does not " &
    "borrow")
  result.add SainRvaRefusal(key: "listItem", symbol: "List<Player>::get_Item",
    why: swNotOffline, detail: "331 arity-matching owners; same generic " &
    "instantiation problem as listCount")
  result.add SainRvaRefusal(key: "glCount", symbol: "List<Throwable>::get_Count",
    why: swNotOffline, detail: "same generic instantiation problem as listCount")
  result.add SainRvaRefusal(key: "glItem", symbol: "List<Throwable>::get_Item",
    why: swNotOffline, detail: "same generic instantiation problem as listItem")

  # --- MIS-SHAPED DRIVE CALLS. These are the dangerous ones: a wrong pick here
  # does not fail, it DRIVES the bot.
  result.add SainRvaRefusal(key: "mvGoTo", symbol: "BotMover::GoToPoint",
    why: swAmbiguous, detail: "the only arity-1 GoToPoint in the image is " &
    "GoToPoint(CustomNavigationPoint) @0x810A50 -- a REFERENCE argument, not " &
    "a Vector3. Binding it would pass the address of this mod's Vector3 where " &
    "the callee expects a managed object. Consequence: bots are never told " &
    "where to go; they keep whatever movement the vanilla brain gives them")
  result.add SainRvaRefusal(key: "mvSprint", symbol: "BotMover::Sprint",
    why: swOwner, detail: "Sprint(bool) is declared on Physical/PhysicalBase, " &
    "NOT on BotMover. Worse: EFT.Player::Sprint(EPlayerState) -> IEnumerator " &
    "@0x71B590 matches this mod's name AND arity, so a by-name lookup would " &
    "WRONGLY TAKE IT and start a coroutine with a bool reinterpreted as an " &
    "enum. Refusing by name is the entire value of this row. The real " &
    "post-1.0 target is IPhysical::Sprint(bool) -- abstract on the interface, " &
    "so the concrete body is PhysicalBase's, reached via EFT.Player.Physical " &
    "@0x9D8. It is a DRIVE call and stays refused pending a human decision")
  result.add SainRvaRefusal(key: "mvStop", symbol: "BotMover::Stop",
    why: swAmbiguous, detail: "109 distinct arity-0 owners of the name Stop. " &
    "Nothing offline distinguishes the bot mover's from the other 108")
  result.add SainRvaRefusal(key: "sdShoot", symbol: "ShootData::Shoot",
    why: swAmbiguous, detail: "ShootData::Shoot @0x1AF7940 and EFT.TestEffect" &
    "::Shoot both match name and arity. Consequence: bots never fire on this " &
    "mod's command")

  # --- AMBIGUOUS until a live receiver is read.
  result.add SainRvaRefusal(key: "aiBotOwner", symbol: "get_BotOwner",
    why: swAmbiguous, detail: "several owners match name and arity; which one " &
    "AIData holds cannot be decided without a live receiver")
  result.add SainRvaRefusal(key: "hcAlive", symbol: "get_IsAlive",
    why: swAmbiguous, detail: "owner ambiguous without a live " &
    "HealthController. Consequence: every player is treated as alive")
  result.add SainRvaRefusal(key: "boBotsGroup", symbol: "get_BotsGroup",
    why: swAmbiguous, detail: "owner ambiguous without a live BotOwner. " &
    "Consequence: the squad layer falls back to same-faction-within-radius")
  result.add SainRvaRefusal(key: "enVisible", symbol: "get_IsVisible",
    why: swAmbiguous, detail: "owner ambiguous without a live EnemyInfo")
  result.add SainRvaRefusal(key: "enCanShoot", symbol: "get_CanShoot",
    why: swAmbiguous, detail: "owner ambiguous without a live EnemyInfo")
  result.add SainRvaRefusal(key: "rlBullets", symbol: "get_BulletCount",
    why: swAmbiguous, detail: "owner ambiguous without a live BotReload")
  result.add SainRvaRefusal(key: "grPosition", symbol: "Throwable::get_Position",
    why: swAmbiguous, detail: "unreachable anyway: wGrenades is refused, so " &
    "no grenade is ever in hand to read a position off")
  result.add SainRvaRefusal(key: "stimHave", symbol: "get_HaveSmth2Use",
    why: swAmbiguous, detail: "the OLD reason -- 'medStims is ABSENT so no " &
    "stimulator component is ever reached' -- IS NO LONGER TRUE: medStims is " &
    "now bound as a field row and a BotStimulators receiver does arrive here. " &
    "The remaining reason is narrower and is the honest one: the bound body " &
    "at 0x8D1B80 is BotAbstractMedsToPart::get_HaveSmth2Use, and whether " &
    "BotStimulators DERIVES from BotAbstractMedsToPart is UNMEASURED. " &
    "'Stimulators' and 'meds to a body part' are not obviously the same " &
    "hierarchy, and a non-virtual call into a base body on a receiver that " &
    "does not derive from it reads that base's field offsets off a foreign " &
    "object. One resolver run on the parent chain settles it; until then this " &
    "refuses. Consequence: canUseStims stays false")

proc findRvaRow*(rows: seq[SainRvaRow]; key: string; hit: var SainRvaRow): bool =
  ## Linear over 23 rows, called once per member at bind time. Capped by
  ## construction: the table is a literal.
  result = false
  var i = 0
  while i < rows.len:
    if rows[i].key == key:
      hit = rows[i]
      return true
    inc i

proc findRvaRefusal*(rs: seq[SainRvaRefusal]; key: string;
                     hit: var SainRvaRefusal): bool =
  result = false
  var i = 0
  while i < rs.len:
    if rs[i].key == key:
      hit = rs[i]
      return true
    inc i
