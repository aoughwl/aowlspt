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

  AimIsReadySpec* =
    "Aiming::get_IsReady@0x1AD48C0/i>i!40534883EC30803DBBB05E0500488BD9"
    ## THE THIRD HOP OF THE AIM ROUTE, as a host patch-by-RVA spec rather than
    ## as a row -- because it is a POSTFIX, not a call.
    ##
    ## Grammar (host `parseRvaSpec`): `Type::Method@0xRVA/<shape>!<prologue>`.
    ## `i` = instance, no declared arguments, `>i` = an integer/bool return.
    ## The 16 bytes after `!` are compared by the host against its STARTUP
    ## SNAPSHOT, not against live memory, so another feature's trampoline
    ## cannot make a correct RVA self-reject.
    ##
    ## WHY A POSTFIX AND NOT A ROW. The old table refused this hop with a real
    ## reason: `AimingManager::get_CurrentAiming` is declared to return the
    ## INTERFACE `IBotAiming`, and `UnderbarrelLauncherBotAiming` implements it
    ## WITHOUT deriving from `Aiming` (MEASURED: it declares its own
    ## `get_IsReady` @0x1AEFE30, SHARED x2). Calling `Aiming`'s body on one of
    ## those would run a foreign body on a foreign receiver, and this build
    ## gives us no way to ask a live object its type.
    ##
    ## A postfix inverts the problem instead of solving it. WE NEVER CALL the
    ## method and never supply a receiver: the game calls it, on whatever
    ## object is really current, and the postfix reads `this` out of the
    ## register the method was entered with. So:
    ##
    ##   * current aiming IS an `Aiming` subclass -- MEASURED that every
    ##     `AimingToXxx` node has base class `Aiming` and declares no
    ##     `get_IsReady` of its own, so all of them inherit this one UNIQUE
    ##     body -- the postfix fires, `this` is that node, and it is the same
    ##     address `amCurrent` handed back. The reading is attributed correctly.
    ##   * current aiming is the underbarrel launcher -- its `get_IsReady` is a
    ##     DIFFERENT address, this postfix never fires for it, no reading is
    ##     ever stored under that key, `aimReadingFor` answers "no reading",
    ##     and the gate does nothing. The bot shoots exactly as it did before
    ##     this sensor existed.
    ##
    ## The wrong-type case therefore costs a MISSING reading, never a wrong
    ## one and never a call into a foreign body. That asymmetry -- the gate can
    ## only ever WITHHOLD, and only on a reading it actually has -- is the
    ## reason this hop is allowed to exist while `hcBodyPart`'s equivalent
    ## ambiguity is still a hard refusal: there is no postfix-shaped way to
    ## read a body part's health.
    ##
    ## SHAREDNESS: `il2cpp_resolve.py shared 0x1AD48C0` says UNIQUE, owners=1.
    ## Detouring a folded address is a write with unbounded blast radius; this
    ## one is not folded. No other RVA in this repo names 0x1AD48C0, so this is
    ## also not a second detour on an already-detoured function.

  DamageShooterSpec* =
    "EFT.Player::OnHealthApplyDamage@0x7395E0/iifV>x!48895C24084889742410574881EC1001"
    ## THE PER-ENEMY "FIRED AT US" SIGNAL, as a PREFIX patch-by-RVA spec.
    ##
    ## `README.md` said this row was blocked because the damage hook could not
    ## name the aggressor. That statement rested on two things, and BOTH have
    ## been re-measured 2026-09-04 and are false today:
    ##
    ##  1. "the DamageInfo arrives as akBigValue, a pointer to a copy the host
    ##     refuses to hand over." MEASURED in `abi/aowlspt_frame.h`:
    ##     `aowl_frame_ptr` accepts `AOWLSPT_ARG_BIGVALUE` explicitly and
    ##     returns the pointer to the copy. It was never refused.
    ##  2. "nothing in the DamageInfo names the shooter." MEASURED with
    ##     `il2cpp_resolve.py ... fields EFT.Ballistics.DamageInfo`: field
    ##     `Player` @0x60, and `EFT.PlayerBridge._player` @0x18 is an
    ##     `EFT.Player` -- the same kind of address `EnemyInfo::get_Person`
    ##     hands back, which is what the enemy table is keyed on. See
    ##     `client/live.nim:shooterFromDamageInfo` for the walk and for the one
    ##     thing it cannot prove.
    ##
    ## WHY THIS METHOD AND NOT `ApplyDamageInfo` OR `ApplyShot`. Slot count.
    ## MEASURED signatures on this build:
    ##
    ##   EFT.Player::ApplyShot(DamageInfo,EBodyPart,EBodyPartColliderType,
    ##                         EArmorPlateCollider,ShotId)  arity 5  -> 6 slots
    ##   EFT.Player::ApplyDamageInfo(DamageInfo,EBodyPart,
    ##                         EBodyPartColliderType,float) arity 4  -> 5 slots
    ##   EFT.Player::OnHealthApplyDamage(EBodyPart,float,DamageInfo)
    ##                                                      arity 3  -> 4 slots
    ##
    ## Only the last fits entirely in RCX/RDX/R8/R9, so it is the only one of
    ## the three whose every argument is readable from the frame at all, and it
    ## is the only one on which a postfix would even be legal. It is bound as a
    ## PREFIX regardless: the handler reads and returns `frameContinue`, and a
    ## prefix cannot be wrong about a return value it never touches.
    ##
    ## SHAPE `iifV>x`: instance, then `i` EBodyPart (enum), `f` float damage,
    ## `V` the value type wider than a register, then a void return.
    ##
    ## SHAREDNESS: `il2cpp_resolve.py shared 0x7395E0` says UNIQUE, owners=1,
    ## section `il2cpp`. No other RVA in this repo names 0x7395E0, so this is
    ## not a second detour on an already-detoured function. The 16 prologue
    ## bytes are what `bytes 0x7395E0 16` printed on 2026-09-04 and the host
    ## compares them against its STARTUP SNAPSHOT.
    ##
    ## WHAT IT DOES NOT DO: it does not replace the existing suppression feed
    ## and it changes no decision by itself. It writes one address and one
    ## timestamp per hit; `core/enemy.nim` already reads `firedAtUsThisTick`
    ## and has done since it was written, against a field nothing ever set.

proc sainRvaLevelFor*(key: string): int =
  ## The minimum `sainRvaTableDriveLevel` at which a key may bind.
  ##
  ## 0 observer / 1 reads / 2 aim / 3 drive. It exists so that "the table is
  ## on" stops meaning "everything the table can do is on" -- which it did
  ## mean, and which quietly put `stLookTo`, a call that turns a live bot's
  ## head, behind the same switch as reading a stamina float.
  ##
  ## DEFAULT 1. A key not named here is a read, and every row and field row in
  ## this file except the two named below IS a read; `resolveFromRva` cannot
  ## express a write at all on the field path and every call row but `stLookTo`
  ## is an arity-0 getter. Naming the exceptions rather than the rule keeps a
  ## newly-added drive call from inheriting "read" by omission -- so any row
  ## added here with a non-zero `argc` and an `fkVoid` return that is NOT in
  ## this list is a table bug, and `sainRvaDriveAudit` below is the check.
  ##
  ## `rlTryReload` is the case the shape heuristic CANNOT see and is why the
  ## audit below is not the whole check: it is `bool TryReload()`, arity 0 with
  ## a value return, so it has the exact shape of a getter -- and it makes the
  ## bot reload its weapon. It is named here by hand, and that is the honest
  ## reason a human still has to read a new row rather than trust the audit.
  if key == "stLookTo" or key == "rlTryReload": return 3
  if key == "boAiming" or key == "amCurrent": return 2
  result = 1

proc sainRvaDriveAudit*(rows: seq[SainRvaRow]): seq[string] =
  ## Every row that LOOKS like a drive call (it takes arguments, or returns
  ## nothing) but is classified as a read by `sainRvaLevelFor`.
  ##
  ## This is the negative check for the paragraph above, and it is written as a
  ## negative on purpose: asserting "stLookTo is level 3" would pass forever
  ## whatever else was added. Asserting "no row that mutates is reachable at
  ## the read level" fails the moment somebody adds one and forgets.
  result = @[]
  var i = 0
  while i < rows.len:
    let r = rows[i]
    if (r.argc != 0'i32 or r.ret == fkVoid) and sainRvaLevelFor(r.key) < 3:
      result.add r.key & " (" & r.label & ") takes " & $r.argc &
                 " argument(s) and returns " & (if r.ret == fkVoid: "void"
                                                else: "a value") &
                 ", which is the shape of a DRIVE call, but sainRvaLevelFor " &
                 "puts it at level " & $sainRvaLevelFor(r.key) &
                 ". A drive call must be level 3."
    inc i

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

  # --- The aim route. THREE hops, and the first two are here as ordinary
  # UNIQUE, non-virtual getters. The third hop is NOT a row: it is a POSTFIX,
  # installed by RVA from `AimIsReadySpec` below, and the reason for the
  # asymmetry is the whole safety argument for this route -- see that constant.
  #
  # `boAiming` USED to be refused. The refusal was correct at the time and its
  # stated ground was precise: binding it would have reported a successful read
  # for a sensor whose only consumer matched the address against a hook on
  # `EFT.BotAimingData::get_IsReady`, a class nothing in the image ever
  # returns, so the key could never match and the check could never fail.
  # THAT GROUND IS GONE, and it is gone because the hook moved, not because
  # anyone changed their mind about the evidence: `sain.nim` now postfixes
  # `Aiming::get_IsReady` @0x1AD48C0 by RVA, and `driver.nim` walks
  # BotOwner -> AimingManager -> CurrentAiming so the address it caches is the
  # very object that postfix is entered with. Re-point first, then bind, in
  # that order -- which is what the old refusal asked for.
  result.add SainRvaRow(key: "boAiming",
    label: "EFT.BotOwner::get_AimingManager",
    rva: 0x80E9B0, prologue: "48 8B 81 90 02 00 00 C3 CC CC CC CC CC CC CC CC",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual. RE-MEASURED for this promotion, not " &
          "copied: `il2cpp_resolve.py member get_AimingManager` finds exactly " &
          "ONE member of that name in all 31,282 types, UNIQUE, arity 0, " &
          "returning AimingManager", needsPlayer: false)
  # Hop 2. Declared return is the INTERFACE `IBotAiming`, and that matters --
  # see `amCurrent`'s entry in the refusal-adjacent notes and the comment on
  # `AimIsReadySpec`. It is safe HERE because nothing calls a method on what
  # comes back: the pointer is used as an IDENTITY and nothing else.
  result.add SainRvaRow(key: "amCurrent",
    label: "AimingManager::get_CurrentAiming",
    rva: 0x23D5B60, prologue: "40 53 48 83 EC 20 80 3D EF CC CE 04 00 48 8B D9",
    argc: 0'i32, ret: fkPtr, shape: srPlain, owners: 1,
    virt: "flags 0x0886 -- non-virtual, UNIQUE. MEASURED: AimingManager holds " &
          "_current (EAimingType) @0x18 and _aimingTypes " &
          "(Dictionary<EAimingType,IBotAiming>) @0x20, so this is a dictionary " &
          "lookup and what comes back is one of the concrete AimingToXxx " &
          "nodes. THE RETURNED POINTER IS NEVER A RECEIVER -- driver.nim " &
          "stores it as an address to match the postfix against, which is why " &
          "the interface return is not a hazard here",
    needsPlayer: false)

  # --- The two safe medical READS that sit next to the three refused medical
  # DRIVE calls. Arity 0, bool, UNIQUE, non-virtual, and neither of them makes
  # a bot do anything: `ShallStartUse` is the game's own answer to "would this
  # component start using itself right now", which is exactly the question
  # `readSelf` was answering with `get_HaveWork`/`get_HaveSmth2Use` alone --
  # i.e. "is there an item" rather than "would the game use it".
  result.add SainRvaRow(key: "surgShall", label: "BotSurgicalKit::ShallStartUse",
    rva: 0x1A24F40, prologue: "40 53 48 83 EC 30 48 8B 05 B3 FA 6A 05 48 8B D9",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0086 -- non-virtual, UNIQUE. Receiver is the BotSurgicalKit " &
          "the bound field row medSurgery (BotMedecine.SurgicalKit@0x28) " &
          "produced, which is itself reached from the UNIQUE " &
          "BotOwner::get_Medecine @0x80ECC0 -- the same chain surgHave " &
          "already uses and is verified by", needsPlayer: false)
  result.add SainRvaRow(key: "faShall", label: "BotFirstAid::ShallStartUse",
    rva: 0x1A203F0, prologue: "40 53 48 83 EC 30 48 8B 11 48 8B D9 0F 29 74 24",
    argc: 0'i32, ret: fkBool, shape: srPlain, owners: 1,
    virt: "flags 0x0086 -- non-virtual, UNIQUE. The SECOND ShallStartUse in " &
          "the image; the other is BotSurgicalKit's above. They are DIFFERENT " &
          "addresses, so the by-name ambiguity that would exist here does not " &
          "reach the table at all. Receiver is the BotFirstAid the bound field " &
          "row medFirstAid (BotMedecine.FirstAid@0x18) produced",
    needsPlayer: false)

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

  # THE AIM ROUTE HAS LEFT THIS TABLE. All three hops were candidates here and
  # all three are now live: `boAiming` (get_AimingManager) and `amCurrent`
  # (get_CurrentAiming) are bound rows above, and `Aiming::get_IsReady` is
  # installed as a POSTFIX from `AimIsReadySpec`. `BotSurgicalKit::
  # ShallStartUse` likewise became the `surgShall` row. Nothing was deleted
  # quietly: each is named at its new home with the measurement that moved it.
  result.add SainRvaCandidate(symbol: "UnderbarrelLauncherBotAiming::get_IsReady",
    rva: 0x1AEFE30, prologue: "",
    argc: 0'i32, owners: 2,
    virt: "flags 0x09E6 -- VIRTUAL+FINAL+NEWSLOT, and SHARED with one other " &
          "method",
    why: "THE OTHER IBotAiming IMPLEMENTOR, recorded because its ABSENCE from " &
         "the aim route is what makes the route safe rather than lucky. " &
         "MEASURED: it declares its own get_IsReady at a different address, " &
         "so it does NOT inherit Aiming::get_IsReady @0x1AD48C0 and does not " &
         "derive from Aiming. When a bot's current aiming is this, the " &
         "postfix simply never fires, no reading is stored, and the aim gate " &
         "withholds nothing. DELIBERATELY NOT BOUND AND NOT HOOKED: its RVA " &
         "is SHARED x2, and a detour on a folded address fires for every " &
         "method that shares it. The prologue is left empty here BECAUSE " &
         "nothing may bind it -- recording bytes for an address this file " &
         "refuses to touch would only make it look ready")

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
  # `boAiming` USED to be refused here, with the longest detail in this file:
  # get_AimingData is genuinely ABSENT, and the reachable replacement was
  # refused anyway because its ONLY consumer matched the address against a
  # postfix on EFT.BotAimingData::get_IsReady -- a class nothing in the image
  # ever returns -- so binding it would have reported a successful read for a
  # dead sensor. That refusal ended with "Re-point the hook first, then bind".
  # THE HOOK HAS BEEN RE-POINTED (see AimIsReadySpec), so the key is now a
  # BOUND ROW. The name get_AimingData is still absent and still not used.

  # --- WRONG ARITY: the name is here, at an arity this mod never calls.
  result.add SainRvaRefusal(key: "hcBodyPart", symbol: "GetBodyPartHealth",
    why: swAmbiguous, detail: "REFUSED ON RECEIVER IDENTITY, which REPLACES " &
    "the arity reason this row used to give. The arity was true and shallow: " &
    "the signature is ValueStruct GetBodyPartHealth(EBodyPart, bool rounded), " &
    "arity 2, and this mod called it at arity 1. Both halves of that are now " &
    "expressible -- the arity, and the Win64 hidden-sret shape a ValueStruct " &
    "return needs -- and the member is STILL refused, for a reason no call-" &
    "site change can reach. THE MEASUREMENT: the receiver comes from " &
    "EFT.Player::get_HealthController, which is `mov rax,[rcx+0xA20]; ret`, " &
    "and EFT.Player._healthController@0xA20 is declared as the INTERFACE " &
    "IHealthController. There are THREE implementations and this build gives " &
    "no way to ask a live object which one it is. Two are ordinary bodies -- " &
    "ObservedPlayerHealthController @0x1E19290 and EFT.HealthInfoAdapter " &
    "@0x8E4930, both UNIQUE, both flags 0x01E6. The third is the one a " &
    "spawned bot almost certainly has, EFT.HealthSystem.ActiveHealthController, " &
    "which inherits BaseHealthController`1::GetBodyPartHealth -- a GENERIC " &
    "with NO methodPointers entry and exactly two instantiated bodies, " &
    "0x3BCC200 (class<object>) and 0x3BD24E0 " &
    "(class<__Il2CppFullySharedGenericType>). BOTH ARE SHARED GENERICS, and a " &
    "shared generic is the ONE case where the trailing MethodInfo* may not be " &
    "NULL: it is where the body reads its type arguments from. The RVA path " &
    "has no MethodInfo to pass. So the three candidate bodies are (a) " &
    "uncallable without a MethodInfo, (b) and (c) correct only for a receiver " &
    "we cannot identify -- and picking wrong runs a foreign body on a foreign " &
    "object, which ANSWERS rather than faults. NOT RECOVERABLE by a call-site " &
    "change; it needs a live type discriminator this build does not offer. " &
    "CONSEQUENCE, unchanged and now stated: readHealth returns its default of " &
    "1.0, so every bot is treated as being at full health, and no decision " &
    "that keys on being hurt can fire. ValueStruct's layout was measured " &
    "anyway so nobody re-derives it: Current@0x10, Maximum@0x14, Minimum@0x18 " &
    "as fieldOffsets reports them, i.e. 0x0/0x4/0x8 into an unboxed 20-byte " &
    "value once the 0x10 object header is removed")
  # --- THE THREE MEDICAL DRIVE CALLS. All three are REFUSED PERMANENTLY, and
  # the ground has changed from "the null-Action argument is unverified" to a
  # MEASUREMENT of what each callee does with that argument. The three bodies
  # were disassembled at their own RVAs against the installed
  # GameAssembly.dll, and they agree exactly:
  #
  #   BotSurgicalKit::ApplyToCurrentPart @0x1A252F0 -- `mov rsi, rdx` takes
  #     the Action, `call` allocates a closure, then `mov [rdi+0x18], rsi`
  #     stores the delegate into it. NO null test anywhere before the store.
  #   BotStimulators::TryApply @0x1A245E0 -- `mov rbp, r9` takes the
  #     Action<bool>, then `mov [rsi+0x18], rbp`. Identical shape.
  #   BotFirstAid::TryApplyToCurrentPart @0x1A20740 -- `mov rsi, r8` takes the
  #     Action, then `mov r8, rsi` and forwards it to 0x181A21E70.
  #
  # THE FINDING, AND IT IS WORSE THAN THE THING WE WERE LOOKING FOR. None of
  # the three dereferences the delegate inside the body at the named RVA -- so
  # the question the refusal was waiting on ("does the callee dereference it
  # unconditionally?") answers NO, and that answer does not clear the call.
  # What each body does is STORE the delegate, unchecked, and hand ownership
  # of the invoke to a continuation that runs later, on the game's own thread,
  # when the animation or the use-timer completes. A null there is a crash
  # that is separated from our call by an unbounded interval and by a stack
  # that contains none of our frames -- the exact failure this project is
  # least able to diagnose and least able to attribute. A store is not proof
  # of safety; it is proof that the proof is not at this address.
  #
  # So: no offline evidence reachable from the callee can settle these, and
  # constructing a real managed Action needs il2cpp_object_new plus a delegate
  # whose method pointer and invoke thunk we would be assembling by hand.
  # REFUSED PERMANENTLY unless somebody builds that delegate properly and can
  # show it being invoked. Consequence: bots never heal, never use a stim and
  # never do surgery on this mod's command; the game's own brain still does
  # all three on its own schedule, which is what it did before SAIN existed.
  # The safe READS beside them are BOUND -- faShall/surgShall (ShallStartUse)
  # and the existing faHave/surgHave -- so the mod can SEE the state it is
  # refusing to drive.
  result.add SainRvaRefusal(key: "faApply",
    symbol: "BotFirstAid::TryApplyToCurrentPart", why: swArity,
    detail: "declared arity 2, DERIVED: void TryApplyToCurrentPart(" &
    "Nullable<int> varianAnim, Action callback) @0x1A20740, UNIQUE, flags " &
    "0x0086 non-virtual. Bindable in principle; REFUSED PERMANENTLY. " &
    "MEASURED at the RVA: the callback arrives in R8, is moved to RSI with " &
    "no null test, and is forwarded in R8 to 0x181A21E70 -- it is never " &
    "invoked in this body, so the delegate's fate is decided somewhere this " &
    "disassembly does not reach, at a time our call does not bound. See the " &
    "block comment above")
  result.add SainRvaRefusal(key: "stimApply", symbol: "BotStimulators::TryApply",
    why: swArity, detail: "declared arity 3, DERIVED: void TryApply(bool " &
    "noCheckDelay, Nullable<int> animVarian, Action<bool> callback) " &
    "@0x1A245E0, UNIQUE, flags 0x0086 non-virtual. REFUSED PERMANENTLY. " &
    "MEASURED at the RVA: the callback arrives in R9, is moved to RBP, and " &
    "is stored into a freshly allocated closure at [rsi+0x18] with no null " &
    "test on any path. Stored, not invoked. See the block comment above")
  result.add SainRvaRefusal(key: "surgApply",
    symbol: "BotSurgicalKit::TryApplyToCurrentPart", why: swArity,
    detail: "the only TryApplyToCurrentPart at a usable owner is arity 2; " &
    "this mod calls it at arity 0. MEASURED: BotSurgicalKit has NO method of " &
    "that name at all -- its equivalent is ApplyToCurrentPart(Action " &
    "callbackEndUse) @0x1A252F0, arity 1, UNIQUE, non-virtual. REFUSED " &
    "PERMANENTLY. MEASURED at that RVA: the Action arrives in RDX, is moved " &
    "to RSI, and after an allocation is stored at [rdi+0x18] with a GC write " &
    "barrier and no null test. Stored, not invoked. See the block comment " &
    "above. The safe READ next to it, ShallStartUse() @0x1A24F40, arity 0, " &
    "bool, UNIQUE, is now the BOUND row surgShall")

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

# ---------------------------------------------------------------------------
# The table's own self-test
# ---------------------------------------------------------------------------

proc hasChar(s: string; c: char): bool =
  result = false
  var i = 0
  while i < s.len:
    if s[i] == c:
      return true
    inc i

proc specField(spec: string; sep: char; idx: int): string =
  ## The `idx`th `sep`-separated field of a spec, or "".
  result = ""
  var seen = 0
  var i = 0
  while i < spec.len:
    if spec[i] == sep:
      inc seen
      if seen > idx:
        return
    elif seen == idx:
      result.add spec[i]
    inc i

proc rvaSelfCheck*(problems: var seq[string]): bool =
  ## Everything about this file that can be decided without a client.
  ##
  ## It is written as a list of NEGATIVES, each of which a plausible future
  ## edit would trip: a drive call classified as a read, a spec with no
  ## prologue to compare, a spec whose declared shape does not match the arity
  ## the handler indexes, an unboxed offset that forgot the object header.
  ## A positive restatement of what is already in the file would pass forever.
  problems = @[]

  # 1. No mutating row is reachable below level 3. Same call the boot report
  #    makes, run here so a `--fast` selftest fails before a raid does.
  let bugs = sainRvaDriveAudit(sainRvaRows())
  var i = 0
  while i < bugs.len:
    problems.add "drive-level audit: " & bugs[i]
    inc i

  # 2. Every row's prologue is 16 bytes, i.e. 47 characters of "XX " pairs.
  #    A short prologue verifies a prefix and passes on a function that merely
  #    STARTS the same way, which on this build is a large family: every
  #    `48 8B 81 ...` field getter begins identically.
  let rows = sainRvaRows()
  i = 0
  while i < rows.len:
    if rows[i].prologue.len != 47:
      problems.add rows[i].key & ": prologue is " & $rows[i].prologue.len &
                   " characters, not the 47 that sixteen space-separated hex " &
                   "bytes take. A short prologue verifies a PREFIX, and on " &
                   "this build whole families of getters share one."
    inc i

  # 3. The two patch-by-RVA specs each carry a prologue at all. A spec with no
  #    `!` parses, installs, and verifies NOTHING -- the exact shape of a check
  #    that cannot fail.
  if not hasChar(AimIsReadySpec, '!'):
    problems.add "AimIsReadySpec carries no ! prologue, so the host would " &
                 "install it without any byte comparison"
  if not hasChar(DamageShooterSpec, '!'):
    problems.add "DamageShooterSpec carries no ! prologue, so the host would " &
                 "install it without any byte comparison"

  # 4. DamageShooterSpec's declared shape must be exactly `iifV>x`, because
  #    `sain.nim` indexes argument 1 for the damage and argument 2 for the
  #    DamageInfo by hand. If the shape ever changes, those indices are wrong
  #    and the handler reads a different register with no complaint from
  #    anybody -- the frame's kind table would agree with the SPEC, which is
  #    the thing that moved.
  let shape = specField(specField(DamageShooterSpec, '!', 0), '/', 1)
  if shape != "iifV>x":
    problems.add "DamageShooterSpec declares the shape '" & shape &
                 "', but sain.nim reads argument 1 as the float damage and " &
                 "argument 2 as the DamageInfo, which only holds for 'iifV>x'"

  result = problems.len == 0
