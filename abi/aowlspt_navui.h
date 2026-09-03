/* aowlspt_navui.h -- UI NAVIGATION TARGETS for the live inspector.
 *
 * The inspector could already READ the running game. These are the first
 * targets that let it DRIVE it: open the settings screen, select a tab. The
 * point is to remove the human step from "open settings, pick the Game tab,
 * look at what appeared" -- a loop that otherwise costs somebody's attention
 * every single time a question is asked.
 *
 * WHY CALL THE GAME'S OWN METHODS RATHER THAN SYNTHESISE INPUT
 * -----------------------------------------------------------
 * A synthetic click has to land on the right screen-space pixel of the right
 * control in the right frame, and it silently does nothing when any of those
 * is wrong. Calling `ShowScreen` / `set_IsSelected` is deterministic, it is
 * the same entry point the game's own button handlers use, and it either runs
 * or faults visibly. The whole design of this instrument is that a failure is
 * loud; a missed click is the opposite of that.
 *
 * PROVENANCE OF EVERY BYTE BELOW
 * ------------------------------
 * These prologues were read directly out of `GameAssembly.dll` at the stated
 * RVAs, via the PE section table (RVA -> file offset), NOT copied from a doc.
 * The reader was validated in the same pass against two targets whose
 * signatures are already baked into `aowlspt_debugui.h`:
 *
 *   Canvas::get_renderMode   @0x5584080  40 53 48 83 EC 20 48 8B 05 73 3E B5 01 48 8B D9
 *   Canvas::get_sortingOrder @0x5584540  40 53 48 83 EC 20 48 8B 05 23 3A B5 01 48 8B D9
 *
 * both of which matched the header byte-for-byte. A reader that reproduces two
 * known answers exactly is a reader whose new answers can be trusted.
 *
 * The same pass also confirmed, as a control, that
 * `TMP_Text::ForceMeshUpdate` @0x628110 begins `C2 00 00` -- `ret 0`, a stub
 * that does nothing. That is why this file carries a SHAPE CHECK as well as a
 * signature check: on UnityEngine and TMP types, "the RVA resolves" is not the
 * same as "the function does anything", and calling a stub is a silent no-op
 * that looks exactly like a failed navigation.
 *
 * Both functions below open with a real register-save prologue
 * (`mov [rsp+x], reg` ...), which is a genuine compiled body -- not a stub
 * (`ret`/`ret n`), and not the IL2CPP internal-call shape
 * (`mov rax,[rip+...]` into a cached native pointer) that the Canvas property
 * getters have. That distinction matters: an icall dereferences the native
 * half of a UnityEngine.Object and faults inside Unity's C++ if that half is
 * gone, which is a fault nothing on our side can guard.
 *
 * VERIFICATION GOES THROUGH THE SNAPSHOT
 * --------------------------------------
 * `aowl_pro_verify` (aowlspt_prologue.h), never a live compare, so that a
 * target another feature has already detoured cannot self-reject. Neither of
 * these is detoured today; that is a property of today's feature set and not
 * a guarantee, which is exactly why it goes through the snapshot anyway.
 */

#ifndef AOWLSPT_NAVUI_H
#define AOWLSPT_NAVUI_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* ---- field offsets on EFT.UI.SettingsScreen / SettingsTab ---- */
#define AOWL_NAV_SS_CURRENTTAB   0x118  /* SettingsScreen._currentTab    ptr  */
#define AOWL_NAV_SS_INITTABS     0x138  /* SettingsScreen._initializedTabs ptr*/
#define AOWL_NAV_TAB_FIRSTSEL    0x090  /* SettingsTab first-select latch     */
#define AOWL_NAV_TAB_CREATED     0x088  /* SettingsTab._createdControls  ptr  */

static int32_t aowl_nav_off_currenttab(void) { return AOWL_NAV_SS_CURRENTTAB; }
static int32_t aowl_nav_off_inittabs(void)   { return AOWL_NAV_SS_INITTABS;   }
static int32_t aowl_nav_off_firstsel(void)   { return AOWL_NAV_TAB_FIRSTSEL;  }
static int32_t aowl_nav_off_created(void)    { return AOWL_NAV_TAB_CREATED;   }

typedef struct AowlNavTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[24];
    int32_t             siglen;
} AowlNavTarget;

static const AowlNavTarget aowl_nav_targets[] = {
    /* EFT.UI.SettingsScreen::ShowScreen -- rcx = screen, edx = group.
     * The selected tab lands at [rcx+0x118] some frames later, which is why
     * the inspector has an `until` primitive: this returns long before the
     * screen it asked for actually exists.
     * NOTE: this function exits by TAIL-JUMP. It is only ever CALLED here,
     * never detoured, so that does not matter to us -- but it would matter a
     * great deal to anyone who tried to postfix it, and it is recorded here so
     * that person does not have to rediscover it. */
    { "EFT.UI.SettingsScreen::ShowScreen", 0x1720DE0u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x48,0x89,0x74,0x24,0x10,
        0x57,
        0x48,0x83,0xEC,0x30,
        0x80 }, 16 },

    /* EFT.UI.SettingsTab::set_IsSelected -- rcx = tab, dl = value.
     * An ordinary `ret`, so it is safe to call and would be safe to detour.
     * Selecting a tab for the FIRST time runs OnFirstSelect (vtable slot 25,
     * [rdx+0x2C8]) -> CreateControls -> SettingsTab::CreateControl<T>, which
     * is what populates _createdControls at +0x88. So the first select costs
     * frames and later ones do not -- another reason to verify with `state`
     * rather than assume. */
    { "EFT.UI.SettingsTab::set_IsSelected", 0x171BCA0u,
      { 0x48,0x89,0x5C,0x24,0x10,
        0x56,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x37,0x88,0x9B }, 16 },

    /* ---- DOWNWARD TRAVERSAL. The inspector could only walk UP a parent
     * chain, which means that from any known object it could never reach a
     * BUTTON -- and so could never click anything. These two are what turn it
     * from a viewer into a harness.
     *
     * Resolved from the DECRYPTED metadata (see docs/METADATA-DECRYPT.md) and
     * then read back out of GameAssembly.dll twice, independently, before
     * being written here. */

    /* UnityEngine.Transform::GetChild(int) -- rcx = transform, edx = index.
     * A real body that forwards to an icall, so the native half must be
     * checked before calling. Returns a Transform. */
    { "UnityEngine.Transform::GetChild", 0x52BA180u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x6F,0xAA,0xE1 }, 16 },

    /* UnityEngine.Transform::get_childCount -- rcx = transform.
     * INTERNAL CALL shape (`mov rax,[rip+..]` into a cached native pointer).
     * It dereferences m_CachedPtr at +0x10 and faults inside Unity's C++ if
     * that is null, which is unguardable from our side -- hence the liveness
     * check every caller here performs first. */
    { "UnityEngine.Transform::get_childCount", 0x52B9CA0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x03,0xAF,0xE1,0x01,
        0x48,0x8B,0xD9 }, 16 },

    /* ---- ACTIVATION. Two routes, deliberately.
     *
     * `Button::Press` is the game's OWN path: it re-checks IsActive and
     * IsInteractable itself and then fires m_OnClick, exactly as a real click
     * does. That is what `click` uses, because reproducing the game's path is
     * always safer than reproducing its effect.
     *
     * `UnityEvent::Invoke` fires a UnityEvent directly, skipping those checks.
     * That is what `invoke` uses, for the case where a control is deliberately
     * non-interactable but the handler still needs to run. Two commands rather
     * than one flag, so the log says which was used. */
    { "UnityEngine.UI.Button::Press", 0x539A7A0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xCC,0xC5,0xD3,0x01,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* ---- THE MISSING LINK: Transform -> Button.
     *
     * `children` and `find` return TRANSFORMS. A Transform is not a Button, so
     * reading Button offsets off one produces garbage that looks plausible --
     * which is exactly what happened: +0x100 read back the RectTransform KLASS
     * pointer and was reported as `m_OnClick`, identically for two different
     * objects.
     *
     * `Component::GetComponent(System.String)` is the route chosen over the
     * three alternatives, and the reason is worth recording because the
     * obvious choice is the wrong one on this build:
     *
     *   * GetComponent(System.Type) needs a live System.Type, which needs an
     *     Il2CppClass*, which needs reflection -- and this project's standing
     *     verdict is that most of the reflection surface FAULTS here. Worse,
     *     no probe verdict for `il2cpp_class_from_name` was ever written down,
     *     so it is an unknown, not a known-good.
     *   * GetComponent<T> is shared generic code. `AddComponent<T>` @0x2A9AE90
     *     does `cmp qword [rdx+0x38], 0` fourteen bytes in, so a NULL
     *     MethodInfo faults immediately, and recovering a real one means
     *     locating that instantiation's specific lazily-filled .data slot.
     *   * The STRING overload needs NO klass, NO System.Type, NO MethodInfo
     *     and NO reflection. Its only dependency is `il2cpp_string_new`, which
     *     is already live-proven on the Unity thread by the version brand.
     *
     * A Transform IS a Component, so this takes what `children` already hands
     * back, with no conversion step to get wrong.
     *
     *   RCX = Component* (a Transform is fine)
     *   RDX = Il2CppString* from il2cpp_string_new("Button")
     *   R8  = NULL MethodInfo* -- the wrapper never reads it
     *
     * CORROBORATED: this is an icall wrapper, and the icall name string it
     * resolves sits at RVA 0x58F9AA0 and reads, verbatim,
     * "UnityEngine.Component::GetComponent(System.String)". An RVA whose own
     * code points at a string naming the method is about as strong as static
     * confirmation gets.
     *
     * CAVEAT, recorded rather than glossed: Unity matches the string overload
     * by SHORT type name, and that "Button" resolves to UnityEngine.UI.Button
     * on this build is a RUNTIME question that no amount of metadata reading
     * settles. The command reports a NULL return as an answer, not a failure,
     * and suggests a fully-qualified name. */
    { "UnityEngine.Component::GetComponent(String)", 0x52A48E0u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x07,0xFC,0xE2 }, 16 },

    /* ---- SCENE ROOTS: breaking the reachability circle.
     *
     * Every search the inspector can do is limited to a hierarchy it already
     * holds a pointer into. In the menu the only live anchor is a PreloaderUI
     * object, so `find` could only ever walk the "Preloader UI" tree -- while
     * the mode selector and the settings screen live under a DIFFERENT scene
     * root that the host only learns once that screen has been opened. That is
     * circular: you need to find the tile in order to open the thing that
     * would have told you where the tile is. Enumerating scene roots is the
     * only way out, and it is why this is the highest-value entry in the file.
     *
     * THE STRUCT-RETURN QUESTION, ANSWERED FROM THE DISASSEMBLY.
     * `Scene` is a 4-byte struct (one int32 handle). The worry with any
     * by-value struct return on Win64 is a hidden sret pointer in RCX with the
     * real arguments shifted right, which would silently corrupt every call.
     * That is NOT what happens here. `GetSceneAt` starts `40 53 / 48 83 EC 20
     * / 80 3D .. 00 / 8B D9` -- `mov ebx, ecx` reads RCX as the INDEX, not as
     * an sret pointer -- and ends `mov eax, [rsp+0x30] / ret`, returning the
     * handle in EAX. The sret dance exists only INSIDE, for its own icall.
     * So these are plain integer calls.
     *
     * The `*Internal(int handle)` forms are used for labelling because they
     * take the handle BY VALUE in ECX -- no struct-`this` pointer to build and
     * nothing to box. `GetRootGameObjects()` is the exception: it is an
     * instance method whose `this` really is a POINTER to the 4-byte handle
     * (its body begins by dereferencing RCX), so the handle goes in a C static
     * and its address is passed. It is preferred over
     * `GetRootGameObjectsInternal` anyway, because the Internal form demands a
     * `List<GameObject>` in RDX that we would have to construct ourselves.
     *
     * It ALLOCATES (a List and an array) and runs class-init on first use, so
     * it belongs in an on-demand command and never in a per-frame path. */
    { "UnityEngine.SceneManagement.SceneManager::get_sceneCount", 0x52C4830u,
      { 0x48,0x83,0xEC,0x28,
        0x48,0x8B,0x05,0x05,0x07,0xE1,0x01,
        0x48,0x85,0xC0,0x75,0x18 }, 16 },

    { "UnityEngine.SceneManagement.SceneManager::GetSceneAt", 0x52C4A40u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xFE,0x04,0xE1,0x01,0x00,
        0x8B,0xD9,0x75 }, 16 },

    { "UnityEngine.SceneManagement.Scene::GetNameInternal", 0x52C3A90u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x53,0x14,0xE1,0x01,
        0x8B,0xD9,0x48 }, 16 },

    { "UnityEngine.SceneManagement.Scene::GetIsLoadedInternal", 0x52C3B40u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0xB3,0x13,0xE1,0x01,
        0x8B,0xD9,0x48 }, 16 },

    { "UnityEngine.SceneManagement.Scene::GetRootCountInternal", 0x52C3BE0u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x23,0x13,0xE1,0x01,
        0x8B,0xD9,0x48 }, 16 },

    /* UnityEngine.GameObject::get_scene_Injected -- rcx = GameObject,
     * rdx = Scene* OUT PARAM.
     *
     * WHY THIS EXISTS, AND WHY IT IS NOT A FALLBACK GUESS.
     * `SceneManager` reported three loaded scenes, all with rootCount 0, on a
     * client whose menu demonstrably has thousands of live objects. That is
     * not a bug in the enumeration -- `GetNameInternal` and
     * `GetIsLoadedInternal` return correct answers for the same handles, which
     * proves handle acquisition and the by-value Scene convention are right,
     * so `GetRootCountInternal` returning 0 is Unity's real answer. The UI
     * simply does not live in any scene SceneManager enumerates; on this build
     * it has been moved to the DontDestroyOnLoad scene, which
     * `sceneCount`/`GetSceneAt` deliberately exclude.
     *
     * So instead of guessing, we ASK: given an object we know is alive, which
     * scene does Unity say it belongs to? That handle then goes through the
     * exact same root enumeration as any other. It is a real answer from the
     * runtime, not a hierarchy climb dressed up as a scene root.
     *
     * The INJECTED form is used deliberately over the plain `get_scene`
     * @0x52A9260. `get_scene` returns a 4-byte struct by value and would make
     * us reason about the return convention again; the injected form writes
     * through an out-pointer we supply, so there is nothing left to infer. */
    { "UnityEngine.GameObject::get_scene_Injected", 0x52A92C0u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x27,0xB3,0xE2 }, 16 },

    { "UnityEngine.SceneManagement.Scene::GetRootGameObjects", 0x52C3ED0u,
      { 0x48,0x89,0x5C,0x24,0x10,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0x3F,0x10,0xE1,0x01 }, 16 },

    { "UnityEngine.Events.UnityEvent::Invoke", 0x52C34A0u,
      { 0x48,0x89,0x5C,0x24,0x18,
        0x48,0x89,0x6C,0x24,0x20,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x80 }, 16 },

    /* ---- ENUMERATING COMPONENTS, instead of guessing type names one at a
     * time and paying a fault for the unlucky guesses. See
     * `abi/aowlspt_components.h` for the whole argument; these are the two
     * calls it needs.
     *
     * `System.Type::GetTypeFromHandle(RuntimeTypeHandle)` is how `typeof(T)`
     * is compiled. `RuntimeTypeHandle` is a ONE-FIELD struct whose value is
     * the `Il2CppType*`, so on Win64 it arrives as a plain pointer in RCX --
     * there is no by-value struct dance and no sret. The body confirms it:
     * `40 53 / 48 83 EC 20 / 80 3D .. 00` (a class-init check) then
     * `48 8B D9` -- `mov rbx, rcx` reads RCX as the VALUE. It is static, so
     * the trailing MethodInfo* goes in RDX, and NULL is fine: it is not a
     * shared generic.
     *
     * The `Il2CppType*` itself is never searched for at runtime. It is a
     * static address in `.data`, resolved OFFLINE by
     * `tools/il2cpp_nameindex.py` and served from the same index the by-RVA
     * binder already uses, under the key `Ns.Type::@type/0`.
     *
     * This route replaces the export chain further down this file
     * (domain -> assemblies -> image -> class_from_name -> class_get_type ->
     * type_get_object). Six exported calls versus one managed call at a
     * byte-verified RVA, on a build whose standing verdict is that the
     * exported reflection surface faults. The old chain was DELETED on
     * 2026-09-03: it was unreferenced, and it called two token-gated exports
     * with no token. Nothing may re-bind them by name here. */
    /* ---- THE OVERLOAD THAT WAS MISSING, AND THE FAULTS IT EXPLAINS.
     *
     * `component EXPR Type` has only ever called the COMPONENT overload
     * (0x52A48E0). Handed a GameObject -- which is what `$rgoN` binds, what
     * `component` itself leaves in `$comp` when the caller looked one up, and
     * what several screen-walking helpers hand back -- that is a NATIVE TYPE
     * CONFUSION: both classes carry `m_CachedPtr` at +0x10, so the liveness
     * pre-check passes and the icall then reads a native GameObject through a
     * native Component layout, inside Unity's C++ where no guard of ours
     * reaches. `duOk` says yes, `iUnityAlive` says yes, and it faults anyway.
     *
     * That is a HYPOTHESIS for the observed "faults on one node, answers
     * cleanly on another" and it is stated as one. What is not hypothetical is
     * that calling the Component overload on a GameObject is wrong, that the
     * right overload exists at 0x52A8510, and that which one to use is decided
     * from the klass pointer for free, before anything is called. A fault that
     * can be avoided by picking the right function should never be spent. */
    /* ---- CORRECTED 2026-09-02: THIS RVA IS THE **Type** OVERLOAD.
     *
     * It was in this table as "GameObject::GetComponent(String)" and it is
     * not one. MEASURED, offline, out of this build's own metadata:
     *
     *   python tools/il2cpp_resolve.py <GameAssembly.dll> <metadata.dec.dat> \
     *          typemethods UnityEngine.GameObject   | grep GetComponent
     *   -> Component GetComponent(Type type)   arity=1  RVA=0x52a8510  UNIQUE
     *
     * `UnityEngine.GameObject` declares NO `GetComponent(string)` overload at
     * all on this build -- only `UnityEngine.Component` does (0x52A48E0,
     * "Component GetComponent(string type)", also confirmed by typemethods).
     * So every caller that picked "the GameObject overload" for a GameObject
     * receiver and then passed an `Il2CppString*` was calling
     * GetComponent(Type) with a String in RDX. That is a managed type
     * confusion inside Unity's own code, and it is the measured cause of
     * `component <GameObject> TextMeshProUGUI` faulting 5/5 tonight.
     *
     * The name is corrected rather than kept for compatibility: a table entry
     * that names the wrong signature is exactly the confidently-wrong answer
     * this instrument exists to abolish. Only inspect.nim looked this one up.
     * (`Component::GetComponent(String)` @0x52A48E0 above is untouched and IS
     * correctly named -- other host files depend on it.) */
    { "UnityEngine.GameObject::GetComponent(Type)", 0x52A8510u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0x17,0xC0,0xE2 }, 16 },

    /* ---- `UnityEngine.Component::GetComponent(Type)` -- THE PREDICATE THAT
     * ACTUALLY SEES A TextMeshProUGUI.
     *
     *   typemethods UnityEngine.Component:
     *     Component GetComponent(Type type)  arity=1  RVA=0x52a45e0  UNIQUE
     *
     * WHY IT IS NEEDED, MEASURED: the String overload (0x52A48E0) never
     * faults and never answers -- `findtext e $settings 40000 all` visited
     * ALL 1263 nodes of an OPEN Settings screen and returned 0 hits, while
     * `label` reads TMP text off those same nodes. Unity's string overload
     * matches by a runtime type-name lookup that does not resolve
     * "TextMeshProUGUI" on this IL2CPP build, so it returns NULL for every
     * node: a predicate that cannot say yes, i.e. every absence verdict
     * findtext ever gave was vacuous.
     *
     * The Type overload takes a live `System.Type`, which is reachable with
     * NO reflection: the static `Il2CppType*` comes out of the offline name
     * index (`TMPro.TextMeshProUGUI::@type/0` -> RVA 0x6F91860) and
     * `System.Type::GetTypeFromHandle` (already in this table) turns it into
     * the Type object. That is the same route `components` already uses, and
     * unlike `GetComponents(Type)` this one ALLOCATES NOTHING, so it is legal
     * in a per-node walk.
     *
     * A Transform IS a Component, so this takes exactly what the traversal
     * already holds, with no GameObject conversion to get wrong. */
    { "UnityEngine.Component::GetComponent(Type)", 0x52A45E0u,
      { 0x48,0x89,0x5C,0x24,0x08,
        0x57,
        0x48,0x83,0xEC,0x20,
        0x48,0x8B,0x05,0xF7,0xFE,0xE2 }, 16 },

    { "System.Type::GetTypeFromHandle", 0x458B020u,
      { 0x40,0x53,
        0x48,0x83,0xEC,0x20,
        0x80,0x3D,0xC2,0x1E,0xB4,0x02,0x00,
        0x48,0x8B,0xD9 }, 16 },

    /* `UnityEngine.GameObject::GetComponents(Type) -> Component[]`. A real
     * managed body, not an icall and not a stub: it opens a frame and does a
     * class-init check before delegating to `GetComponentsInternal/6`. It
     * ALLOCATES (a Type-keyed array), so it belongs in an on-demand command
     * and must never appear in a per-frame path. */
    { "UnityEngine.GameObject::GetComponents(Type)", 0x52A8760u,
      { 0x48,0x89,0x74,0x24,0x10,
        0x57,
        0x48,0x83,0xEC,0x40,
        0x80,0x3D,0xEF,0xBD,0xE2,0x01 }, 16 },

    /* ---- CLICK RECORDER. Which UI element the human just clicked.
     *
     * `EventSystem::get_current` is a STATIC getter (no `this`; the trailing
     * MethodInfo* lands in RCX and NULL is fine -- it is not generic). It
     * returns the singleton EventSystem, whose `currentSelectedGameObject`
     * lives at [this+0x40] -- confirmed by that getter's own inlined body
     * `48 8B 41 40 C3` (mov rax,[rcx+0x40]; ret), so the recorder reads the
     * field directly and never has to call the FOLDED (shared) getter RVA.
     * get_current is UNIQUE and a real body (measured: sharedness=UNIQUE,
     * owners=1), so detour-blast-radius does not apply -- and we only CALL it.
     * Resolved offline via tools/il2cpp_resolve.py (rid 1615). */
    { "UnityEngine.EventSystems.EventSystem::get_current", 0x55C71E0u,
      { 0x48,0x83,0xEC,0x28,
        0x80,0x3D,0xC5,0x0F,0xB1,0x01,0x00,
        0x75,0x3A,
        0x48,0x8D,0x0D }, 16 },
};

/* EventSystem.m_CurrentSelected -> GameObject, from get_currentSelectedGameObject's
 * inlined body `mov rax,[rcx+0x40]; ret` @0x6A9390. */
#define AOWL_NAV_ES_CURSELECTED  0x040
static int32_t aowl_nav_off_curselected(void) { return AOWL_NAV_ES_CURSELECTED; }

/* ---- FIELD OFFSETS, corroborated by the accessors' own inlined bodies.
 *
 * These are not guesses from a dump; each one is confirmed by disassembling
 * the property getter, which on this build is inlined to a single load:
 *
 *   Button::get_onClick          @0x691570  48 8B 81 00 01 00 00 C3
 *                                           mov rax,[rcx+0x100]; ret
 *   Selectable::get_interactable @0x7DC330  0F B6 81 D8 00 00 00 C3
 *                                           movzx eax,byte [rcx+0xD8]; ret
 *   Toggle::get_isOn             @0x66E7C0  0F B6 81 20 01 00 00 C3
 *                                           movzx eax,byte [rcx+0x120]; ret
 *
 * A getter that IS the field read is the strongest possible evidence for an
 * offset, and it means the inspector can read all three with NO CALL AT ALL --
 * no icall, no native dereference, nothing that can fault inside Unity. */
#define AOWL_NAV_BTN_ONCLICK     0x100  /* Button.m_OnClick -> UnityEvent    */
#define AOWL_NAV_SEL_INTERACT    0x0D8  /* Selectable.m_Interactable  bool   */
#define AOWL_NAV_TOG_ISON        0x120  /* Toggle.m_IsOn              bool   */
#define AOWL_NAV_TOG_ONVALUE     0x118  /* Toggle.onValueChanged -> event    */
#define AOWL_NAV_UOBJ_CACHEDPTR  0x010  /* UnityEngine.Object.m_CachedPtr    */

/* ------------------------------------------------------------------ *
/* ------------------------------------------------------------------ *
 * REMOVED 2026-09-03 -- the domain -> assembly -> image -> class -> type
 * route that used to live here.
 *
 * It bound `il2cpp_class_from_name` (NONCE gate) and `il2cpp_class_get_type`
 * (STATIC gate) with a raw GetProcAddress and called them with NO TOKEN, so
 * each returned MT19937-64 output that passed the `if (!klass)` / `if (!ty)`
 * check on the next line -- invariant X1 of docs/INTERACTION-LAYER-MAP.md
 * section 3, and the exact shape that killed the client on 2026-09-02 18:49.
 *
 * It is DELETED rather than routed through `aowl_gate_call`, because nothing
 * ever called it: `aowl_nav_find_class`, `aowl_nav_type_object`,
 * `aowl_nav_have_type_route` and `aowl_nav_last_hop` had no importc on the
 * Nim side and no C caller. A dead hazard is removed, not hardened.
 *
 * If a System.Type is needed again, use `aowl_mi2_type_object_of`
 * (abi/aowlspt_invoke2.h), which goes through the armed gate plus
 * `aowl_handle_shape_ok`. Do not re-bind these exports by name here.
 * ------------------------------------------------------------------ */

/* ---- THE PRE-FLIGHT PROBE for the string route.
 *
 * The GetComponent wrapper's failure branch RAISES a missing-method exception
 * when the icall is not registered. A managed exception thrown from inside our
 * own call, on the Unity thread, is not something to discover empirically.
 *
 * `il2cpp_resolve_icall` is exported and answers the question directly and
 * off the hot path: non-NULL means the icall is registered and that branch is
 * unreachable. Asking first costs one call; not asking risks a throw inside a
 * detour. */
typedef void* (*AowlNavResolveIcall)(const char*);
static AowlNavResolveIcall g_nav_resolve_icall = 0;
static int                 g_nav_icall_probed  = 0;
static int32_t             g_nav_icall_ok      = 0;

static int32_t aowl_nav_icall_ready(void) {
    HMODULE ga;
    if (g_nav_icall_probed) return g_nav_icall_ok;
    g_nav_icall_probed = 1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return 0;
    g_nav_resolve_icall = (AowlNavResolveIcall)(void*)
        GetProcAddress(ga, "il2cpp_resolve_icall");
    if (!g_nav_resolve_icall) return 0;
    g_nav_icall_ok = g_nav_resolve_icall(
        "UnityEngine.Component::GetComponent(System.String)") ? 1 : 0;
    return g_nav_icall_ok;
}


/* ---- MANAGED ARRAY LAYOUT, corroborated by the runtime's OWN accessors.
 *
 * These are not assumptions. GameAssembly.dll exports functions whose entire
 * body is the constant in question, read straight out of the image:
 *
 *   il2cpp_array_length                         @0x00F2C0  8B 41 18 C3
 *                                               mov eax,[rcx+0x18]; ret
 *   il2cpp_array_object_header_size             @0x5B3B20  B8 20 00 00 00 C3
 *                                               return 0x20
 *   il2cpp_offset_of_array_length_in_array_...  @0x5B3B30  B8 18 00 00 00 C3
 *                                               return 0x18
 *
 * So: int32 length at +0x18, first element at +0x20, 8 bytes per element on
 * x64. The runtime says so itself. */
#define AOWL_NAV_ARR_LEN   0x18
#define AOWL_NAV_ARR_DATA  0x20

static int32_t aowl_nav_off_arrlen(void)  { return AOWL_NAV_ARR_LEN;  }
static int32_t aowl_nav_off_arrdata(void) { return AOWL_NAV_ARR_DATA; }

/* `Scene::GetRootGameObjects()` is an instance method on a 4-byte struct, so
 * its `this` is a POINTER to the handle rather than the handle itself. This
 * static is that storage: set the handle, pass the address. One slot is enough
 * because the call is synchronous and the inspector is single-threaded per
 * batch. */
static int32_t aowl_nav_scene_handle = 0;
static void aowl_nav_set_scene_handle(int32_t h) { aowl_nav_scene_handle = h; }
static void* aowl_nav_scene_handle_ptr(void) { return (void*)&aowl_nav_scene_handle; }

static int32_t aowl_nav_off_onclick(void)   { return AOWL_NAV_BTN_ONCLICK;    }
static int32_t aowl_nav_off_interact(void)  { return AOWL_NAV_SEL_INTERACT;   }
static int32_t aowl_nav_off_ison(void)      { return AOWL_NAV_TOG_ISON;       }
static int32_t aowl_nav_off_onvalue(void)   { return AOWL_NAV_TOG_ONVALUE;    }
static int32_t aowl_nav_off_cachedptr(void) { return AOWL_NAV_UOBJ_CACHEDPTR; }

#define AOWL_NAV_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_nav_targets) / sizeof(aowl_nav_targets[0])))

static int32_t aowl_nav_stub_rejects = 0;

/* Is this code a do-nothing stub? `C3` (ret) or `C2 xx xx` (ret n) as the very
 * first instruction means calling it accomplishes nothing. TMP's
 * ForceMeshUpdate @0x628110 is exactly this. A stub that passes a signature
 * check is the worst kind of target: every call "succeeds" and nothing
 * happens, which is indistinguishable from a click that missed. */
static int32_t aowl_nav_is_stub(const unsigned char* p) {
    if (p[0] == 0xC3) return 1;
    if (p[0] == 0xC2) return 1;
    return 0;
}

/* WHY A VERIFY FAILURE MUST NAME ITSELF.
 *
 * `aowl_nav_verify` has five independent ways to say no, and the first version
 * of this file collapsed all of them into a single NULL. The caller then
 * printed "did not verify on this build (or is a stub)" -- a message that
 * covers a wrong RVA, an unmapped page, a non-executable page, a genuine
 * signature mismatch and a stub, and distinguishes none of them. That is
 * precisely the shape of message that has cost this project a full
 * deploy/launch cycle every time it has appeared.
 *
 * So the reason is recorded, and so are the bytes actually found, and the
 * caller prints both. One run now answers what previously took several. */
#define AOWL_NAV_OK          0
#define AOWL_NAV_NO_MODULE   1
#define AOWL_NAV_NO_QUERY    2
#define AOWL_NAV_NOT_COMMIT  3
#define AOWL_NAV_NOT_EXEC    4
#define AOWL_NAV_SIG_MISMATCH 5
#define AOWL_NAV_STUB        6
#define AOWL_NAV_PRO_FULL    7   /* OURS: the shared prologue snapshot
                                     * table was full; the RVA was never
                                     * captured. NOT a client change. */

static int32_t       aowl_nav_reason = AOWL_NAV_OK;
static unsigned char aowl_nav_actual[AOWL_PRO_MAX_BYTES];
static int32_t       aowl_nav_actual_ok = 0;

static void* aowl_nav_verify(uint32_t rva, const unsigned char* sig,
                             int32_t siglen) {
    HMODULE ga;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    aowl_nav_reason = AOWL_NAV_OK;
    aowl_nav_actual_ok = 0;

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_nav_reason = AOWL_NAV_NO_MODULE; return NULL; }
    p = (unsigned char*)ga + rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) {
        aowl_nav_reason = AOWL_NAV_NO_QUERY; return NULL; }
    if (mbi.State != MEM_COMMIT) {
        aowl_nav_reason = AOWL_NAV_NOT_COMMIT; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_nav_reason = AOWL_NAV_NOT_EXEC; return NULL; }

    /* Record what is REALLY there, so a mismatch can be shown rather than
     * merely asserted. Safe: the page passed the checks above. */
    memcpy(aowl_nav_actual, p, AOWL_PRO_MAX_BYTES);
    aowl_nav_actual_ok = 1;

    /* THE STUB CHECK READS THE ACTUAL CODE, NOT THE SIGNATURE.
     * The first version tested `sig` -- the bytes we EXPECT -- which can never
     * detect a stub, because a signature copied from a real function never
     * starts with `ret`. The whole point is to catch a target whose LIVE bytes
     * are a stub, so it has to read `p`. */
    if (aowl_nav_is_stub(p)) {
        aowl_nav_stub_rejects++;
        aowl_nav_reason = AOWL_NAV_STUB;
        return NULL;
    }
    /* Against the SNAPSHOT, never live memory. */
    if (siglen > 0 && !aowl_pro_verify(rva, sig, siglen)) {
        /* TWO DIFFERENT FAILURES, TWO DIFFERENT REASONS. A verify that failed
         * because OUR snapshot table had no free row says nothing about the
         * client, so it is counted separately and never latched as a
         * signature mismatch. See aowl_pro_last_reason_text(). */
        aowl_nav_reason = aowl_pro_last_was_table_full()
                        ? AOWL_NAV_PRO_FULL : AOWL_NAV_SIG_MISMATCH;
        return NULL;
    }
    return (void*)p;
}

static int32_t aowl_nav_last_reason(void) { return aowl_nav_reason; }
static int32_t aowl_nav_actual_valid(void) { return aowl_nav_actual_ok; }
static int32_t aowl_nav_actual_at(int32_t i) {
    if (i < 0 || i >= AOWL_PRO_MAX_BYTES) return -1;
    return (int32_t)aowl_nav_actual[i];
}
static int32_t aowl_nav_expected_at(int32_t t, int32_t i) {
    if (t < 0 || t >= AOWL_NAV_TARGET_COUNT) return -1;
    if (i < 0 || i >= AOWL_PRO_MAX_BYTES) return -1;
    return (int32_t)aowl_nav_targets[t].sig[i];
}

static void* aowl_nav_target_at(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return NULL;
    return aowl_nav_verify(aowl_nav_targets[i].rva,
                           aowl_nav_targets[i].sig,
                           aowl_nav_targets[i].siglen);
}

static const char* aowl_nav_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return "";
    return aowl_nav_targets[i].name;
}

static uint32_t aowl_nav_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NAV_TARGET_COUNT) return 0u;
    return aowl_nav_targets[i].rva;
}

static int32_t aowl_nav_target_count(void) { return AOWL_NAV_TARGET_COUNT; }

#endif /* AOWLSPT_NAVUI_H */
