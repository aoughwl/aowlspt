/* aowlspt_symtab.h -- GENERATED. DO NOT EDIT.
 *
 * tools/il2cpp_symtab.py gen, from
 *   GameAssembly.dll
 *   aowlspt_symbols.txt
 *
 * Every RVA here was resolved OFFLINE and passed four gates: it is in
 * the `il2cpp` PE section, it is not this build's universal empty-body
 * stub, exactly one method definition owns it (unless it is declared
 * shared-call), and its first 16 bytes are recorded below so a later
 * `il2cpp_symtab.py check` can prove the DLL still starts that way.
 *
 * A symbol that failed a gate is defined to an UNDEFINED IDENTIFIER
 * naming the reason: referencing it is a compile error, and not
 * referencing it costs nothing. `check` is the second gate and reports
 * the same thing with a file and line for non-C consumers.
 *
 *
 * HOW TO USE IT
 * -------------
 * C / abi headers:  #include "aowlspt_symtab.h", then use
 *   AOWL_SYM_<NAME> where you had a hex literal. `-I abi` is already on
 *   every host, mod and tool compile (`abiInclude` in tools/aowl.nim).
 * Nim / Nimony:     import the sibling aowlspt_symtab.nim; the same
 *   AOWL_SYM_<NAME> identifiers are exported as `uint32` consts.
 *
 * The RVA is an offset. Add the RUNTIME base of GameAssembly.dll --
 * the DLL is ASLR-relocated and 0x180000000 is only its preferred base,
 * so never add that constant.
 *
 * Nothing here replaces the binder's own safety work: prologue
 * byte-verify against abi/aowlspt_prologue.h's startup snapshot,
 * VirtualQuery on every hop, flag-gated and default-OFF. What it
 * replaces is the by-NAME step, and the _PROLOGUE macro below is the
 * expectation that verify should be fed.
 *
 * Add symbols by editing abi/aowlspt_symbols.txt, never this file.
 */
#ifndef AOWLSPT_SYMTAB_H
#define AOWLSPT_SYMTAB_H

#define AOWL_SYMTAB_MAGIC   "AOWLSYMTAB"
#define AOWL_SYMTAB_VERSION 1
/* Build identity of the GameAssembly.dll every RVA below came from.
 * (timeDateStamp << 32) | SizeOfImage -- a mapped module can report both,
 * so a host may cross-check this against the process it is inside. */
#define AOWL_SYMTAB_IMAGE_KEY 0x6A7CA21C078F0000ull
#define AOWL_SYMTAB_FILE_SHA256 "e0ea3ad3b76bc0b9da4a385ea0aa22b8158e98a380e105cb6e6cc44f73857483"
#define AOWL_SYMTAB_PROLOGUE_LEN 16
/* This build's universal empty-body stub, found by owner count AND
 * opcode shape, not hardcoded. Anything landing here is REJECTED. */
#define AOWL_SYMTAB_UNIVERSAL_STUB_RVA 0x00628110u
#define AOWL_SYMTAB_UNIVERSAL_STUB_OWNERS 9614

/* 70 accepted, 7 shared-call escape hatch, 1 rejected. */

/* ---- detour-safe and call-safe: exactly one owner ------------- */

/* Transform get_transform()
 *   UnityEngine.GameObject::get_transform/0
 *   RVA 0x052A8AE0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GO_GET_TRANSFORM               0x052A8AE0u
#define AOWL_SYM_GO_GET_TRANSFORM_ARITY 0
#define AOWL_SYM_GO_GET_TRANSFORM_OWNERS 1
#define AOWL_SYM_GO_GET_TRANSFORM_NAME "UnityEngine.GameObject::get_transform/0"
#define AOWL_SYM_GO_GET_TRANSFORM_SECTION "il2cpp"
#define AOWL_SYM_GO_GET_TRANSFORM_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x93,0xBA,0xE2,0x01,0x48,0x8B,0xD9

/* void SetActive(bool value)
 *   UnityEngine.GameObject::SetActive/1
 *   RVA 0x052A8BE0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_GO_SET_ACTIVE                  0x052A8BE0u
#define AOWL_SYM_GO_SET_ACTIVE_ARITY 1
#define AOWL_SYM_GO_SET_ACTIVE_OWNERS 1
#define AOWL_SYM_GO_SET_ACTIVE_NAME "UnityEngine.GameObject::SetActive/1"
#define AOWL_SYM_GO_SET_ACTIVE_SECTION "il2cpp"
#define AOWL_SYM_GO_SET_ACTIVE_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xA7,0xB9,0xE2

/* bool get_activeSelf()
 *   UnityEngine.GameObject::get_activeSelf/0
 *   RVA 0x052A8C40  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GO_ACTIVE_SELF                 0x052A8C40u
#define AOWL_SYM_GO_ACTIVE_SELF_ARITY 0
#define AOWL_SYM_GO_ACTIVE_SELF_OWNERS 1
#define AOWL_SYM_GO_ACTIVE_SELF_NAME "UnityEngine.GameObject::get_activeSelf/0"
#define AOWL_SYM_GO_ACTIVE_SELF_SECTION "il2cpp"
#define AOWL_SYM_GO_ACTIVE_SELF_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x53,0xB9,0xE2,0x01,0x48,0x8B,0xD9

/* bool get_activeInHierarchy()
 *   UnityEngine.GameObject::get_activeInHierarchy/0
 *   RVA 0x052A8C90  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY         0x052A8C90u
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY_ARITY 0
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY_OWNERS 1
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY_NAME "UnityEngine.GameObject::get_activeInHierarchy/0"
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY_SECTION "il2cpp"
#define AOWL_SYM_GO_ACTIVE_IN_HIERARCHY_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x0B,0xB9,0xE2,0x01,0x48,0x8B,0xD9

/* int get_layer()
 *   UnityEngine.GameObject::get_layer/0
 *   RVA 0x052A8B30  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GO_GET_LAYER                   0x052A8B30u
#define AOWL_SYM_GO_GET_LAYER_ARITY 0
#define AOWL_SYM_GO_GET_LAYER_OWNERS 1
#define AOWL_SYM_GO_GET_LAYER_NAME "UnityEngine.GameObject::get_layer/0"
#define AOWL_SYM_GO_GET_LAYER_SECTION "il2cpp"
#define AOWL_SYM_GO_GET_LAYER_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x4B,0xBA,0xE2,0x01,0x48,0x8B,0xD9

/* void get_scene_Injected(Scene ret)
 *   UnityEngine.GameObject::get_scene_Injected/1
 *   RVA 0x052A92C0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_GO_GET_SCENE_INJECTED          0x052A92C0u
#define AOWL_SYM_GO_GET_SCENE_INJECTED_ARITY 1
#define AOWL_SYM_GO_GET_SCENE_INJECTED_OWNERS 1
#define AOWL_SYM_GO_GET_SCENE_INJECTED_NAME "UnityEngine.GameObject::get_scene_Injected/1"
#define AOWL_SYM_GO_GET_SCENE_INJECTED_SECTION "il2cpp"
#define AOWL_SYM_GO_GET_SCENE_INJECTED_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x27,0xB3,0xE2

/* string get_name()
 *   UnityEngine.Object::get_name/0
 *   RVA 0x052AD4B0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_OBJ_GET_NAME                   0x052AD4B0u
#define AOWL_SYM_OBJ_GET_NAME_ARITY 0
#define AOWL_SYM_OBJ_GET_NAME_OWNERS 1
#define AOWL_SYM_OBJ_GET_NAME_NAME "UnityEngine.Object::get_name/0"
#define AOWL_SYM_OBJ_GET_NAME_SECTION "il2cpp"
#define AOWL_SYM_OBJ_GET_NAME_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x36,0x72,0xE2,0x01,0x00,0x48,0x8B,0xD9

/* void set_name(string value)
 *   UnityEngine.Object::set_name/1
 *   RVA 0x052AD540  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_OBJ_SET_NAME                   0x052AD540u
#define AOWL_SYM_OBJ_SET_NAME_ARITY 1
#define AOWL_SYM_OBJ_SET_NAME_OWNERS 1
#define AOWL_SYM_OBJ_SET_NAME_NAME "UnityEngine.Object::set_name/1"
#define AOWL_SYM_OBJ_SET_NAME_SECTION "il2cpp"
#define AOWL_SYM_OBJ_SET_NAME_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xA3,0x71,0xE2,0x01

/* int GetInstanceID()
 *   UnityEngine.Object::GetInstanceID/0
 *   RVA 0x052ACFD0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_OBJ_GET_INSTANCE_ID            0x052ACFD0u
#define AOWL_SYM_OBJ_GET_INSTANCE_ID_ARITY 0
#define AOWL_SYM_OBJ_GET_INSTANCE_ID_OWNERS 1
#define AOWL_SYM_OBJ_GET_INSTANCE_ID_NAME "UnityEngine.Object::GetInstanceID/0"
#define AOWL_SYM_OBJ_GET_INSTANCE_ID_SECTION "il2cpp"
#define AOWL_SYM_OBJ_GET_INSTANCE_ID_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x12,0x77,0xE2,0x01,0x00,0x48,0x8B,0xD9

/* int get_childCount()
 *   UnityEngine.Transform::get_childCount/0
 *   RVA 0x052B9CA0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TF_GET_CHILD_COUNT             0x052B9CA0u
#define AOWL_SYM_TF_GET_CHILD_COUNT_ARITY 0
#define AOWL_SYM_TF_GET_CHILD_COUNT_OWNERS 1
#define AOWL_SYM_TF_GET_CHILD_COUNT_NAME "UnityEngine.Transform::get_childCount/0"
#define AOWL_SYM_TF_GET_CHILD_COUNT_SECTION "il2cpp"
#define AOWL_SYM_TF_GET_CHILD_COUNT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x03,0xAF,0xE1,0x01,0x48,0x8B,0xD9

/* Transform GetChild(int index)
 *   UnityEngine.Transform::GetChild/1
 *   RVA 0x052BA180  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TF_GET_CHILD                   0x052BA180u
#define AOWL_SYM_TF_GET_CHILD_ARITY 1
#define AOWL_SYM_TF_GET_CHILD_OWNERS 1
#define AOWL_SYM_TF_GET_CHILD_NAME "UnityEngine.Transform::GetChild/1"
#define AOWL_SYM_TF_GET_CHILD_SECTION "il2cpp"
#define AOWL_SYM_TF_GET_CHILD_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x6F,0xAA,0xE1

/* void SetAsFirstSibling()
 *   UnityEngine.Transform::SetAsFirstSibling/0
 *   RVA 0x052B9CF0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING        0x052B9CF0u
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING_ARITY 0
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING_OWNERS 1
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING_NAME "UnityEngine.Transform::SetAsFirstSibling/0"
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING_SECTION "il2cpp"
#define AOWL_SYM_TF_SET_AS_FIRST_SIBLING_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xBB,0xAE,0xE1,0x01,0x48,0x8B,0xD9

/* Vector3 get_localPosition()
 *   UnityEngine.Transform::get_localPosition/0
 *   RVA 0x052B71B0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TF_GET_LOCAL_POSITION          0x052B71B0u
#define AOWL_SYM_TF_GET_LOCAL_POSITION_ARITY 0
#define AOWL_SYM_TF_GET_LOCAL_POSITION_OWNERS 1
#define AOWL_SYM_TF_GET_LOCAL_POSITION_NAME "UnityEngine.Transform::get_localPosition/0"
#define AOWL_SYM_TF_GET_LOCAL_POSITION_SECTION "il2cpp"
#define AOWL_SYM_TF_GET_LOCAL_POSITION_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xFA,0x48

/* void set_localPosition(Vector3 value)
 *   UnityEngine.Transform::set_localPosition/1
 *   RVA 0x052B7220  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TF_SET_LOCAL_POSITION          0x052B7220u
#define AOWL_SYM_TF_SET_LOCAL_POSITION_ARITY 1
#define AOWL_SYM_TF_SET_LOCAL_POSITION_OWNERS 1
#define AOWL_SYM_TF_SET_LOCAL_POSITION_NAME "UnityEngine.Transform::set_localPosition/1"
#define AOWL_SYM_TF_SET_LOCAL_POSITION_SECTION "il2cpp"
#define AOWL_SYM_TF_SET_LOCAL_POSITION_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xEF,0xD9,0xE1

/* Vector3 get_localScale()
 *   UnityEngine.Transform::get_localScale/0
 *   RVA 0x052B8100  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TF_GET_LOCAL_SCALE             0x052B8100u
#define AOWL_SYM_TF_GET_LOCAL_SCALE_ARITY 0
#define AOWL_SYM_TF_GET_LOCAL_SCALE_OWNERS 1
#define AOWL_SYM_TF_GET_LOCAL_SCALE_NAME "UnityEngine.Transform::get_localScale/0"
#define AOWL_SYM_TF_GET_LOCAL_SCALE_SECTION "il2cpp"
#define AOWL_SYM_TF_GET_LOCAL_SCALE_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xFA,0x48

/* void set_localScale(Vector3 value)
 *   UnityEngine.Transform::set_localScale/1
 *   RVA 0x052B8170  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TF_SET_LOCAL_SCALE             0x052B8170u
#define AOWL_SYM_TF_SET_LOCAL_SCALE_ARITY 1
#define AOWL_SYM_TF_SET_LOCAL_SCALE_OWNERS 1
#define AOWL_SYM_TF_SET_LOCAL_SCALE_NAME "UnityEngine.Transform::set_localScale/1"
#define AOWL_SYM_TF_SET_LOCAL_SCALE_SECTION "il2cpp"
#define AOWL_SYM_TF_SET_LOCAL_SCALE_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xCF,0xCA,0xE1

/* Rect get_rect()
 *   UnityEngine.RectTransform::get_rect/0
 *   RVA 0x052B5240  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_RECT                    0x052B5240u
#define AOWL_SYM_RT_GET_RECT_ARITY 0
#define AOWL_SYM_RT_GET_RECT_OWNERS 1
#define AOWL_SYM_RT_GET_RECT_NAME "UnityEngine.RectTransform::get_rect/0"
#define AOWL_SYM_RT_GET_RECT_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_RECT_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xDF,0xF8,0xE1

/* Vector2 get_anchorMin()
 *   UnityEngine.RectTransform::get_anchorMin/0
 *   RVA 0x052B52B0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_ANCHOR_MIN              0x052B52B0u
#define AOWL_SYM_RT_GET_ANCHOR_MIN_ARITY 0
#define AOWL_SYM_RT_GET_ANCHOR_MIN_OWNERS 1
#define AOWL_SYM_RT_GET_ANCHOR_MIN_NAME "UnityEngine.RectTransform::get_anchorMin/0"
#define AOWL_SYM_RT_GET_ANCHOR_MIN_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_ANCHOR_MIN_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,0x44,0x24,0x40

/* void set_anchorMin(Vector2 value)
 *   UnityEngine.RectTransform::set_anchorMin/1
 *   RVA 0x052B5310  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_RT_SET_ANCHOR_MIN              0x052B5310u
#define AOWL_SYM_RT_SET_ANCHOR_MIN_ARITY 1
#define AOWL_SYM_RT_SET_ANCHOR_MIN_OWNERS 1
#define AOWL_SYM_RT_SET_ANCHOR_MIN_NAME "UnityEngine.RectTransform::set_anchorMin/1"
#define AOWL_SYM_RT_SET_ANCHOR_MIN_SECTION "il2cpp"
#define AOWL_SYM_RT_SET_ANCHOR_MIN_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x23,0xF8,0xE1,0x01,0x48,0x8B,0xD9

/* Vector2 get_anchorMax()
 *   UnityEngine.RectTransform::get_anchorMax/0
 *   RVA 0x052B5370  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_ANCHOR_MAX              0x052B5370u
#define AOWL_SYM_RT_GET_ANCHOR_MAX_ARITY 0
#define AOWL_SYM_RT_GET_ANCHOR_MAX_OWNERS 1
#define AOWL_SYM_RT_GET_ANCHOR_MAX_NAME "UnityEngine.RectTransform::get_anchorMax/0"
#define AOWL_SYM_RT_GET_ANCHOR_MAX_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_ANCHOR_MAX_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,0x44,0x24,0x40

/* void set_anchorMax(Vector2 value)
 *   UnityEngine.RectTransform::set_anchorMax/1
 *   RVA 0x052B53D0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_RT_SET_ANCHOR_MAX              0x052B53D0u
#define AOWL_SYM_RT_SET_ANCHOR_MAX_ARITY 1
#define AOWL_SYM_RT_SET_ANCHOR_MAX_OWNERS 1
#define AOWL_SYM_RT_SET_ANCHOR_MAX_NAME "UnityEngine.RectTransform::set_anchorMax/1"
#define AOWL_SYM_RT_SET_ANCHOR_MAX_SECTION "il2cpp"
#define AOWL_SYM_RT_SET_ANCHOR_MAX_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x73,0xF7,0xE1,0x01,0x48,0x8B,0xD9

/* Vector2 get_anchoredPosition()
 *   UnityEngine.RectTransform::get_anchoredPosition/0
 *   RVA 0x052B5430  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_ANCHORED_POS            0x052B5430u
#define AOWL_SYM_RT_GET_ANCHORED_POS_ARITY 0
#define AOWL_SYM_RT_GET_ANCHORED_POS_OWNERS 1
#define AOWL_SYM_RT_GET_ANCHORED_POS_NAME "UnityEngine.RectTransform::get_anchoredPosition/0"
#define AOWL_SYM_RT_GET_ANCHORED_POS_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_ANCHORED_POS_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,0x44,0x24,0x40

/* void set_anchoredPosition(Vector2 value)
 *   UnityEngine.RectTransform::set_anchoredPosition/1
 *   RVA 0x052B5490  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_RT_SET_ANCHORED_POS            0x052B5490u
#define AOWL_SYM_RT_SET_ANCHORED_POS_ARITY 1
#define AOWL_SYM_RT_SET_ANCHORED_POS_OWNERS 1
#define AOWL_SYM_RT_SET_ANCHORED_POS_NAME "UnityEngine.RectTransform::set_anchoredPosition/1"
#define AOWL_SYM_RT_SET_ANCHORED_POS_SECTION "il2cpp"
#define AOWL_SYM_RT_SET_ANCHORED_POS_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0xC3,0xF6,0xE1,0x01,0x48,0x8B,0xD9

/* Vector2 get_sizeDelta()
 *   UnityEngine.RectTransform::get_sizeDelta/0
 *   RVA 0x052B54F0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_SIZE_DELTA              0x052B54F0u
#define AOWL_SYM_RT_GET_SIZE_DELTA_ARITY 0
#define AOWL_SYM_RT_GET_SIZE_DELTA_OWNERS 1
#define AOWL_SYM_RT_GET_SIZE_DELTA_NAME "UnityEngine.RectTransform::get_sizeDelta/0"
#define AOWL_SYM_RT_GET_SIZE_DELTA_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_SIZE_DELTA_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,0x44,0x24,0x40

/* void set_sizeDelta(Vector2 value)
 *   UnityEngine.RectTransform::set_sizeDelta/1
 *   RVA 0x052B5550  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_RT_SET_SIZE_DELTA              0x052B5550u
#define AOWL_SYM_RT_SET_SIZE_DELTA_ARITY 1
#define AOWL_SYM_RT_SET_SIZE_DELTA_OWNERS 1
#define AOWL_SYM_RT_SET_SIZE_DELTA_NAME "UnityEngine.RectTransform::set_sizeDelta/1"
#define AOWL_SYM_RT_SET_SIZE_DELTA_SECTION "il2cpp"
#define AOWL_SYM_RT_SET_SIZE_DELTA_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x13,0xF6,0xE1,0x01,0x48,0x8B,0xD9

/* Vector2 get_pivot()
 *   UnityEngine.RectTransform::get_pivot/0
 *   RVA 0x052B55B0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_RT_GET_PIVOT                   0x052B55B0u
#define AOWL_SYM_RT_GET_PIVOT_ARITY 0
#define AOWL_SYM_RT_GET_PIVOT_OWNERS 1
#define AOWL_SYM_RT_GET_PIVOT_NAME "UnityEngine.RectTransform::get_pivot/0"
#define AOWL_SYM_RT_GET_PIVOT_SECTION "il2cpp"
#define AOWL_SYM_RT_GET_PIVOT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x33,0xC0,0x48,0x8B,0xD9,0x48,0x89,0x44,0x24,0x40

/* void set_pivot(Vector2 value)
 *   UnityEngine.RectTransform::set_pivot/1
 *   RVA 0x052B5610  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_RT_SET_PIVOT                   0x052B5610u
#define AOWL_SYM_RT_SET_PIVOT_ARITY 1
#define AOWL_SYM_RT_SET_PIVOT_OWNERS 1
#define AOWL_SYM_RT_SET_PIVOT_NAME "UnityEngine.RectTransform::set_pivot/1"
#define AOWL_SYM_RT_SET_PIVOT_SECTION "il2cpp"
#define AOWL_SYM_RT_SET_PIVOT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x48,0x8B,0x05,0x63,0xF5,0xE1,0x01,0x48,0x8B,0xD9

/* RenderMode get_renderMode()
 *   UnityEngine.Canvas::get_renderMode/0
 *   RVA 0x05584080  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_CANVAS_GET_RENDER_MODE         0x05584080u
#define AOWL_SYM_CANVAS_GET_RENDER_MODE_ARITY 0
#define AOWL_SYM_CANVAS_GET_RENDER_MODE_OWNERS 1
#define AOWL_SYM_CANVAS_GET_RENDER_MODE_NAME "UnityEngine.Canvas::get_renderMode/0"
#define AOWL_SYM_CANVAS_GET_RENDER_MODE_SECTION "il2cpp"
#define AOWL_SYM_CANVAS_GET_RENDER_MODE_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x73,0x3E,0xB5,0x01,0x48,0x8B,0xD9

/* float get_scaleFactor()
 *   UnityEngine.Canvas::get_scaleFactor/0
 *   RVA 0x05584180  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR        0x05584180u
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR_ARITY 0
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR_OWNERS 1
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR_NAME "UnityEngine.Canvas::get_scaleFactor/0"
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR_SECTION "il2cpp"
#define AOWL_SYM_CANVAS_GET_SCALE_FACTOR_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x8B,0x3D,0xB5,0x01,0x48,0x8B,0xD9

/* int get_sortingOrder()
 *   UnityEngine.Canvas::get_sortingOrder/0
 *   RVA 0x05584540  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_CANVAS_GET_SORT_ORDER          0x05584540u
#define AOWL_SYM_CANVAS_GET_SORT_ORDER_ARITY 0
#define AOWL_SYM_CANVAS_GET_SORT_ORDER_OWNERS 1
#define AOWL_SYM_CANVAS_GET_SORT_ORDER_NAME "UnityEngine.Canvas::get_sortingOrder/0"
#define AOWL_SYM_CANVAS_GET_SORT_ORDER_SECTION "il2cpp"
#define AOWL_SYM_CANVAS_GET_SORT_ORDER_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x23,0x3A,0xB5,0x01,0x48,0x8B,0xD9

/* Camera get_main()
 *   UnityEngine.Camera::get_main/0
 *   RVA 0x05260400  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_CAMERA_GET_MAIN                0x05260400u
#define AOWL_SYM_CAMERA_GET_MAIN_ARITY 0
#define AOWL_SYM_CAMERA_GET_MAIN_OWNERS 1
#define AOWL_SYM_CAMERA_GET_MAIN_NAME "UnityEngine.Camera::get_main/0"
#define AOWL_SYM_CAMERA_GET_MAIN_SECTION "il2cpp"
#define AOWL_SYM_CAMERA_GET_MAIN_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0xD5,0x27,0xE7,0x01,0x48,0x85,0xC0,0x75,0x18

/* int get_frameCount()
 *   UnityEngine.Time::get_frameCount/0
 *   RVA 0x052B3400  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TIME_GET_FRAME_COUNT           0x052B3400u
#define AOWL_SYM_TIME_GET_FRAME_COUNT_ARITY 0
#define AOWL_SYM_TIME_GET_FRAME_COUNT_OWNERS 1
#define AOWL_SYM_TIME_GET_FRAME_COUNT_NAME "UnityEngine.Time::get_frameCount/0"
#define AOWL_SYM_TIME_GET_FRAME_COUNT_SECTION "il2cpp"
#define AOWL_SYM_TIME_GET_FRAME_COUNT_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x5D,0x16,0xE2,0x01,0x48,0x85,0xC0,0x75,0x18

/* string GetNameInternal(int sceneHandle)
 *   UnityEngine.SceneManagement.Scene::GetNameInternal/1
 *   RVA 0x052C3A90  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SCENE_GET_NAME                 0x052C3A90u
#define AOWL_SYM_SCENE_GET_NAME_ARITY 1
#define AOWL_SYM_SCENE_GET_NAME_OWNERS 1
#define AOWL_SYM_SCENE_GET_NAME_NAME "UnityEngine.SceneManagement.Scene::GetNameInternal/1"
#define AOWL_SYM_SCENE_GET_NAME_SECTION "il2cpp"
#define AOWL_SYM_SCENE_GET_NAME_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x53,0x14,0xE1,0x01,0x8B,0xD9,0x48

/* bool GetIsLoadedInternal(int sceneHandle)
 *   UnityEngine.SceneManagement.Scene::GetIsLoadedInternal/1
 *   RVA 0x052C3B40  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SCENE_GET_IS_LOADED            0x052C3B40u
#define AOWL_SYM_SCENE_GET_IS_LOADED_ARITY 1
#define AOWL_SYM_SCENE_GET_IS_LOADED_OWNERS 1
#define AOWL_SYM_SCENE_GET_IS_LOADED_NAME "UnityEngine.SceneManagement.Scene::GetIsLoadedInternal/1"
#define AOWL_SYM_SCENE_GET_IS_LOADED_SECTION "il2cpp"
#define AOWL_SYM_SCENE_GET_IS_LOADED_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xB3,0x13,0xE1,0x01,0x8B,0xD9,0x48

/* int GetRootCountInternal(int sceneHandle)
 *   UnityEngine.SceneManagement.Scene::GetRootCountInternal/1
 *   RVA 0x052C3BE0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SCENE_GET_ROOT_COUNT           0x052C3BE0u
#define AOWL_SYM_SCENE_GET_ROOT_COUNT_ARITY 1
#define AOWL_SYM_SCENE_GET_ROOT_COUNT_OWNERS 1
#define AOWL_SYM_SCENE_GET_ROOT_COUNT_NAME "UnityEngine.SceneManagement.Scene::GetRootCountInternal/1"
#define AOWL_SYM_SCENE_GET_ROOT_COUNT_SECTION "il2cpp"
#define AOWL_SYM_SCENE_GET_ROOT_COUNT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x23,0x13,0xE1,0x01,0x8B,0xD9,0x48

/* int get_sceneCount()
 *   UnityEngine.SceneManagement.SceneManager::get_sceneCount/0
 *   RVA 0x052C4830  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_SCENEMGR_GET_COUNT             0x052C4830u
#define AOWL_SYM_SCENEMGR_GET_COUNT_ARITY 0
#define AOWL_SYM_SCENEMGR_GET_COUNT_OWNERS 1
#define AOWL_SYM_SCENEMGR_GET_COUNT_NAME "UnityEngine.SceneManagement.SceneManager::get_sceneCount/0"
#define AOWL_SYM_SCENEMGR_GET_COUNT_SECTION "il2cpp"
#define AOWL_SYM_SCENEMGR_GET_COUNT_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x05,0x07,0xE1,0x01,0x48,0x85,0xC0,0x75,0x18

/* Scene GetSceneAt(int index)
 *   UnityEngine.SceneManagement.SceneManager::GetSceneAt/1
 *   RVA 0x052C4A40  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SCENEMGR_GET_AT                0x052C4A40u
#define AOWL_SYM_SCENEMGR_GET_AT_ARITY 1
#define AOWL_SYM_SCENEMGR_GET_AT_OWNERS 1
#define AOWL_SYM_SCENEMGR_GET_AT_NAME "UnityEngine.SceneManagement.SceneManager::GetSceneAt/1"
#define AOWL_SYM_SCENEMGR_GET_AT_SECTION "il2cpp"
#define AOWL_SYM_SCENEMGR_GET_AT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xFE,0x04,0xE1,0x01,0x00,0x8B,0xD9,0x75

/* void Invoke()
 *   UnityEngine.Events.UnityEvent::Invoke/0
 *   RVA 0x052C34A0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_UNITYEVENT_INVOKE              0x052C34A0u
#define AOWL_SYM_UNITYEVENT_INVOKE_ARITY 0
#define AOWL_SYM_UNITYEVENT_INVOKE_OWNERS 1
#define AOWL_SYM_UNITYEVENT_INVOKE_NAME "UnityEngine.Events.UnityEvent::Invoke/0"
#define AOWL_SYM_UNITYEVENT_INVOKE_SECTION "il2cpp"
#define AOWL_SYM_UNITYEVENT_INVOKE_PROLOGUE 0x48,0x89,0x5C,0x24,0x18,0x48,0x89,0x6C,0x24,0x20,0x57,0x48,0x83,0xEC,0x20,0x80

/* void Press()
 *   UnityEngine.UI.Button::Press/0
 *   RVA 0x0539A7A0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_BUTTON_PRESS                   0x0539A7A0u
#define AOWL_SYM_BUTTON_PRESS_ARITY 0
#define AOWL_SYM_BUTTON_PRESS_OWNERS 1
#define AOWL_SYM_BUTTON_PRESS_NAME "UnityEngine.UI.Button::Press/0"
#define AOWL_SYM_BUTTON_PRESS_SECTION "il2cpp"
#define AOWL_SYM_BUTTON_PRESS_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xCC,0xC5,0xD3,0x01,0x00,0x48,0x8B,0xD9

/* void set_raycastTarget(bool value)
 *   UnityEngine.UI.Graphic::set_raycastTarget/1
 *   RVA 0x053AD7F0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_GRAPHIC_SET_RAYCAST            0x053AD7F0u
#define AOWL_SYM_GRAPHIC_SET_RAYCAST_ARITY 1
#define AOWL_SYM_GRAPHIC_SET_RAYCAST_OWNERS 1
#define AOWL_SYM_GRAPHIC_SET_RAYCAST_NAME "UnityEngine.UI.Graphic::set_raycastTarget/1"
#define AOWL_SYM_GRAPHIC_SET_RAYCAST_SECTION "il2cpp"
#define AOWL_SYM_GRAPHIC_SET_RAYCAST_PROLOGUE 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xDA,0x95,0xD2,0x01

/* void set_minValue(float value)
 *   UnityEngine.UI.Slider::set_minValue/1
 *   RVA 0x055B3250  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SLIDER_SET_MIN                 0x055B3250u
#define AOWL_SYM_SLIDER_SET_MIN_ARITY 1
#define AOWL_SYM_SLIDER_SET_MIN_OWNERS 1
#define AOWL_SYM_SLIDER_SET_MIN_NAME "UnityEngine.UI.Slider::set_minValue/1"
#define AOWL_SYM_SLIDER_SET_MIN_SECTION "il2cpp"
#define AOWL_SYM_SLIDER_SET_MIN_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0xD4,0x4E,0xB2,0x01,0x00,0x48,0x8B,0xD9

/* void set_maxValue(float value)
 *   UnityEngine.UI.Slider::set_maxValue/1
 *   RVA 0x055B32D0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SLIDER_SET_MAX                 0x055B32D0u
#define AOWL_SYM_SLIDER_SET_MAX_ARITY 1
#define AOWL_SYM_SLIDER_SET_MAX_OWNERS 1
#define AOWL_SYM_SLIDER_SET_MAX_NAME "UnityEngine.UI.Slider::set_maxValue/1"
#define AOWL_SYM_SLIDER_SET_MAX_SECTION "il2cpp"
#define AOWL_SYM_SLIDER_SET_MAX_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0x55,0x4E,0xB2,0x01,0x00,0x48,0x8B,0xD9

/* void SetValueWithoutNotify(float input)
 *   UnityEngine.UI.Slider::SetValueWithoutNotify/1
 *   RVA 0x055B3420  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY           0x055B3420u
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY_ARITY 1
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY_OWNERS 1
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY_NAME "UnityEngine.UI.Slider::SetValueWithoutNotify/1"
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY_SECTION "il2cpp"
#define AOWL_SYM_SLIDER_SET_NO_NOTIFY_PROLOGUE 0x4C,0x8B,0x09,0x45,0x33,0xC0,0x49,0x8B,0x81,0x88,0x04,0x00,0x00,0x4D,0x8B,0x89

/* void UpdateVisuals()
 *   UnityEngine.UI.Slider::UpdateVisuals/0
 *   RVA 0x055B4610  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_SLIDER_UPDATE_VISUALS          0x055B4610u
#define AOWL_SYM_SLIDER_UPDATE_VISUALS_ARITY 0
#define AOWL_SYM_SLIDER_UPDATE_VISUALS_OWNERS 1
#define AOWL_SYM_SLIDER_UPDATE_VISUALS_NAME "UnityEngine.UI.Slider::UpdateVisuals/0"
#define AOWL_SYM_SLIDER_UPDATE_VISUALS_SECTION "il2cpp"
#define AOWL_SYM_SLIDER_UPDATE_VISUALS_PROLOGUE 0x48,0x89,0x5C,0x24,0x20,0x57,0x48,0x83,0xEC,0x70,0x80,0x3D,0x17,0x3B,0xB2,0x01

/* void set_isOn(bool value)
 *   UnityEngine.UI.Toggle::set_isOn/1
 *   RVA 0x055BA430  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TOGGLE_SET_IS_ON               0x055BA430u
#define AOWL_SYM_TOGGLE_SET_IS_ON_ARITY 1
#define AOWL_SYM_TOGGLE_SET_IS_ON_OWNERS 1
#define AOWL_SYM_TOGGLE_SET_IS_ON_NAME "UnityEngine.UI.Toggle::set_isOn/1"
#define AOWL_SYM_TOGGLE_SET_IS_ON_SECTION "il2cpp"
#define AOWL_SYM_TOGGLE_SET_IS_ON_PROLOGUE 0x45,0x33,0xC9,0x41,0xB0,0x01,0xE9,0x15,0x00,0x00,0x00,0xCC,0xCC,0xCC,0xCC,0xCC

/* void SetIsOnWithoutNotify(bool value)
 *   UnityEngine.UI.Toggle::SetIsOnWithoutNotify/1
 *   RVA 0x055BA440  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY           0x055BA440u
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY_ARITY 1
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY_OWNERS 1
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY_NAME "UnityEngine.UI.Toggle::SetIsOnWithoutNotify/1"
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY_SECTION "il2cpp"
#define AOWL_SYM_TOGGLE_SET_NO_NOTIFY_PROLOGUE 0x45,0x33,0xC9,0x45,0x33,0xC0,0xE9,0x05,0x00,0x00,0x00,0xCC,0xCC,0xCC,0xCC,0xCC

/* Type GetTypeFromHandle(RuntimeTypeHandle handle)
 *   System.Type::GetTypeFromHandle/1
 *   RVA 0x0458B020  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TYPE_FROM_HANDLE               0x0458B020u
#define AOWL_SYM_TYPE_FROM_HANDLE_ARITY 1
#define AOWL_SYM_TYPE_FROM_HANDLE_OWNERS 1
#define AOWL_SYM_TYPE_FROM_HANDLE_NAME "System.Type::GetTypeFromHandle/1"
#define AOWL_SYM_TYPE_FROM_HANDLE_SECTION "il2cpp"
#define AOWL_SYM_TYPE_FROM_HANDLE_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0xC2,0x1E,0xB4,0x02,0x00,0x48,0x8B,0xD9

/* void set_text(string value)
 *   TMPro.TMP_Text::set_text/1
 *   RVA 0x051BC1E0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TMP_SET_TEXT                   0x051BC1E0u
#define AOWL_SYM_TMP_SET_TEXT_ARITY 1
#define AOWL_SYM_TMP_SET_TEXT_OWNERS 1
#define AOWL_SYM_TMP_SET_TEXT_NAME "TMPro.TMP_Text::set_text/1"
#define AOWL_SYM_TMP_SET_TEXT_SECTION "il2cpp"
#define AOWL_SYM_TMP_SET_TEXT_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0xB9,0xE8,0x00,0x00,0x00

/* void set_havePropertiesChanged(bool value)
 *   TMPro.TMP_Text::set_havePropertiesChanged/1
 *   RVA 0x051BEA30  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_TMP_SET_PROPS_CHANGED          0x051BEA30u
#define AOWL_SYM_TMP_SET_PROPS_CHANGED_ARITY 1
#define AOWL_SYM_TMP_SET_PROPS_CHANGED_OWNERS 1
#define AOWL_SYM_TMP_SET_PROPS_CHANGED_NAME "TMPro.TMP_Text::set_havePropertiesChanged/1"
#define AOWL_SYM_TMP_SET_PROPS_CHANGED_SECTION "il2cpp"
#define AOWL_SYM_TMP_SET_PROPS_CHANGED_PROLOGUE 0x38,0x91,0x78,0x03,0x00,0x00,0x74,0x1A,0x88,0x91,0x78,0x03,0x00,0x00,0x48,0x8B

/* void SetParentAndAlign(GameObject child, GameObject parent)
 *   TMPro.TMP_DefaultControls::SetParentAndAlign/2
 *   RVA 0x051903A0  section il2cpp  owners 1  arity 2
 */
#define AOWL_SYM_TMP_SET_PARENT_ALIGN           0x051903A0u
#define AOWL_SYM_TMP_SET_PARENT_ALIGN_ARITY 2
#define AOWL_SYM_TMP_SET_PARENT_ALIGN_OWNERS 1
#define AOWL_SYM_TMP_SET_PARENT_ALIGN_NAME "TMPro.TMP_DefaultControls::SetParentAndAlign/2"
#define AOWL_SYM_TMP_SET_PARENT_ALIGN_SECTION "il2cpp"
#define AOWL_SYM_TMP_SET_PARENT_ALIGN_PROLOGUE 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x68,0x13,0xF4,0x01

/* void ForceMeshUpdate(bool ignoreActiveState, bool forceTextReparsing)
 *   TMPro.TextMeshProUGUI::ForceMeshUpdate/2
 *   RVA 0x05180F80  section il2cpp  owners 1  arity 2
 */
#define AOWL_SYM_TMPUGUI_FORCE_MESH             0x05180F80u
#define AOWL_SYM_TMPUGUI_FORCE_MESH_ARITY 2
#define AOWL_SYM_TMPUGUI_FORCE_MESH_OWNERS 1
#define AOWL_SYM_TMPUGUI_FORCE_MESH_NAME "TMPro.TextMeshProUGUI::ForceMeshUpdate/2"
#define AOWL_SYM_TMPUGUI_FORCE_MESH_SECTION "il2cpp"
#define AOWL_SYM_TMPUGUI_FORCE_MESH_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x2F,0x07,0xF5,0x01

/* void ForceMeshUpdate(bool ignoreActiveState, bool forceTextReparsing)
 *   TMPro.TextMeshPro::ForceMeshUpdate/2
 *   RVA 0x05174690  section il2cpp  owners 1  arity 2
 */
#define AOWL_SYM_TMPPRO_FORCE_MESH              0x05174690u
#define AOWL_SYM_TMPPRO_FORCE_MESH_ARITY 2
#define AOWL_SYM_TMPPRO_FORCE_MESH_OWNERS 1
#define AOWL_SYM_TMPPRO_FORCE_MESH_NAME "TMPro.TextMeshPro::ForceMeshUpdate/2"
#define AOWL_SYM_TMPPRO_FORCE_MESH_SECTION "il2cpp"
#define AOWL_SYM_TMPPRO_FORCE_MESH_PROLOGUE 0x88,0x91,0xB4,0x06,0x00,0x00,0x33,0xD2,0xC6,0x81,0x78,0x03,0x00,0x00,0x01,0xE9

/* void SetLabelText(string text)
 *   EFT.UI.LocalizedText::SetLabelText/1
 *   RVA 0x0140FE70  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_LOCTEXT_SET_LABEL              0x0140FE70u
#define AOWL_SYM_LOCTEXT_SET_LABEL_ARITY 1
#define AOWL_SYM_LOCTEXT_SET_LABEL_OWNERS 1
#define AOWL_SYM_LOCTEXT_SET_LABEL_NAME "EFT.UI.LocalizedText::SetLabelText/1"
#define AOWL_SYM_LOCTEXT_SET_LABEL_SECTION "il2cpp"
#define AOWL_SYM_LOCTEXT_SET_LABEL_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x60,0x48,0x8B,0xFA,0x48,0x8B,0xD9

/* void ShowScreen(ESettingsGroup group)
 *   EFT.UI.Settings.SettingsScreen::ShowScreen/1
 *   RVA 0x01720DE0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SETTINGSSCREEN_SHOW1           0x01720DE0u
#define AOWL_SYM_SETTINGSSCREEN_SHOW1_ARITY 1
#define AOWL_SYM_SETTINGSSCREEN_SHOW1_OWNERS 1
#define AOWL_SYM_SETTINGSSCREEN_SHOW1_NAME "EFT.UI.Settings.SettingsScreen::ShowScreen/1"
#define AOWL_SYM_SETTINGSSCREEN_SHOW1_SECTION "il2cpp"
#define AOWL_SYM_SETTINGSSCREEN_SHOW1_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x30,0x80

/* void set_IsSelected(bool value)
 *   EFT.UI.Settings.SettingsTab::set_IsSelected/1
 *   RVA 0x0171BCA0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SETTINGSTAB_SET_SEL            0x0171BCA0u
#define AOWL_SYM_SETTINGSTAB_SET_SEL_ARITY 1
#define AOWL_SYM_SETTINGSTAB_SET_SEL_OWNERS 1
#define AOWL_SYM_SETTINGSTAB_SET_SEL_NAME "EFT.UI.Settings.SettingsTab::set_IsSelected/1"
#define AOWL_SYM_SETTINGSTAB_SET_SEL_SECTION "il2cpp"
#define AOWL_SYM_SETTINGSTAB_SET_SEL_PROLOGUE 0x48,0x89,0x5C,0x24,0x10,0x56,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x37,0x88,0x9B

/* void Update()
 *   EFT.UI.Settings.GameSettingsTab::Update/0
 *   RVA 0x01703680  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE         0x01703680u
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE_ARITY 0
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE_OWNERS 1
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE_NAME "EFT.UI.Settings.GameSettingsTab::Update/0"
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE_SECTION "il2cpp"
#define AOWL_SYM_GAMESETTINGSTAB_UPDATE_PROLOGUE 0x40,0x57,0x48,0x83,0xEC,0x40,0x80,0x3D,0xE2,0xAC,0x9B,0x05,0x00,0x48,0x8B,0xF9

/* void Update()
 *   EFT.TarkovApplication::Update/0
 *   RVA 0x00977B10  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_TARKOVAPP_UPDATE               0x00977B10u
#define AOWL_SYM_TARKOVAPP_UPDATE_ARITY 0
#define AOWL_SYM_TARKOVAPP_UPDATE_OWNERS 1
#define AOWL_SYM_TARKOVAPP_UPDATE_NAME "EFT.TarkovApplication::Update/0"
#define AOWL_SYM_TARKOVAPP_UPDATE_SECTION "il2cpp"
#define AOWL_SYM_TARKOVAPP_UPDATE_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x99,0x10,0x01,0x00,0x00,0x48,0x85,0xDB

/* void RegisterPlayer(IPlayer iPlayer)
 *   EFT.GameWorld::RegisterPlayer/1
 *   RVA 0x025038C0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_GAMEWORLD_REGISTER             0x025038C0u
#define AOWL_SYM_GAMEWORLD_REGISTER_ARITY 1
#define AOWL_SYM_GAMEWORLD_REGISTER_OWNERS 1
#define AOWL_SYM_GAMEWORLD_REGISTER_NAME "EFT.GameWorld::RegisterPlayer/1"
#define AOWL_SYM_GAMEWORLD_REGISTER_SECTION "il2cpp"
#define AOWL_SYM_GAMEWORLD_REGISTER_PROLOGUE 0x40,0x56,0x41,0x57,0x48,0x81,0xEC,0x88,0x00,0x00,0x00,0x80,0x3D,0x42,0xF6,0xBB

/* void Update()
 *   EFT.GameWorldUnityTickListener::Update/0
 *   RVA 0x0251C6C0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE          0x0251C6C0u
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE_ARITY 0
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE_OWNERS 1
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE_NAME "EFT.GameWorldUnityTickListener::Update/0"
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE_SECTION "il2cpp"
#define AOWL_SYM_GAMEWORLD_TICK_UPDATE_PROLOGUE 0x40,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0xD0,0x68,0xBA,0x04,0x00,0x48,0x8B,0xF9

/* void AddPlayer(Player player)
 *   EFT.BotSpawner::AddPlayer/1
 *   RVA 0x02563AE0  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER          0x02563AE0u
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER_ARITY 1
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER_OWNERS 1
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER_NAME "EFT.BotSpawner::AddPlayer/1"
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER_SECTION "il2cpp"
#define AOWL_SYM_BOTSPAWNER_ADD_PLAYER_PROLOGUE 0x48,0x89,0x5C,0x24,0x18,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x99,0xF6,0xB5,0x04

/* void PreActivate(BotZone zone, GameDateTime time, BotsGroup group, AICoversData covers, bool autoActivate)
 *   EFT.BotOwner::PreActivate/5
 *   RVA 0x00813F60  section il2cpp  owners 1  arity 5
 */
#define AOWL_SYM_BOTOWNER_PREACTIVATE           0x00813F60u
#define AOWL_SYM_BOTOWNER_PREACTIVATE_ARITY 5
#define AOWL_SYM_BOTOWNER_PREACTIVATE_OWNERS 1
#define AOWL_SYM_BOTOWNER_PREACTIVATE_NAME "EFT.BotOwner::PreActivate/5"
#define AOWL_SYM_BOTOWNER_PREACTIVATE_SECTION "il2cpp"
#define AOWL_SYM_BOTOWNER_PREACTIVATE_PROLOGUE 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x48,0x89,0x74,0x24,0x20,0x57

/* void UpdateManual()
 *   EFT.BotOwner::UpdateManual/0
 *   RVA 0x0081B7C0  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL         0x0081B7C0u
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL_ARITY 0
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL_OWNERS 1
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL_NAME "EFT.BotOwner::UpdateManual/0"
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL_SECTION "il2cpp"
#define AOWL_SYM_BOTOWNER_UPDATE_MANUAL_PROLOGUE 0x40,0x53,0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,0x80,0x3D,0x08,0xCF,0x89,0x06,0x00

/* void OnPostRender()
 *   EFT.CameraControl.CameraLodBiasController::OnPostRender/0
 *   RVA 0x01263B10  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_LODBIAS_ON_POST_RENDER         0x01263B10u
#define AOWL_SYM_LODBIAS_ON_POST_RENDER_ARITY 0
#define AOWL_SYM_LODBIAS_ON_POST_RENDER_OWNERS 1
#define AOWL_SYM_LODBIAS_ON_POST_RENDER_NAME "EFT.CameraControl.CameraLodBiasController::OnPostRender/0"
#define AOWL_SYM_LODBIAS_ON_POST_RENDER_SECTION "il2cpp"
#define AOWL_SYM_LODBIAS_ON_POST_RENDER_PROLOGUE 0x48,0x83,0xEC,0x38,0x48,0x8B,0x05,0x4D,0xF7,0xE6,0x05,0x0F,0x29,0x74,0x24,0x20

/* void OnRenderObject()
 *   OnRenderObjectManager::OnRenderObject/0
 *   RVA 0x01F46910  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_ONRENDEROBJ_MANAGER            0x01F46910u
#define AOWL_SYM_ONRENDEROBJ_MANAGER_ARITY 0
#define AOWL_SYM_ONRENDEROBJ_MANAGER_OWNERS 1
#define AOWL_SYM_ONRENDEROBJ_MANAGER_NAME "OnRenderObjectManager::OnRenderObject/0"
#define AOWL_SYM_ONRENDEROBJ_MANAGER_SECTION "il2cpp"
#define AOWL_SYM_ONRENDEROBJ_MANAGER_PROLOGUE 0x40,0x55,0x48,0x83,0xEC,0x20,0x80,0x3D,0x83,0xA8,0x17,0x05,0x00,0x48,0x8B,0xE9

/* void Sprint(bool val, bool withDebugCallback)
 *   BotMover::Sprint/2
 *   RVA 0x01A2D700  section il2cpp  owners 1  arity 2
 */
#define AOWL_SYM_SAIN_MOVER_SPRINT              0x01A2D700u
#define AOWL_SYM_SAIN_MOVER_SPRINT_ARITY 2
#define AOWL_SYM_SAIN_MOVER_SPRINT_OWNERS 1
#define AOWL_SYM_SAIN_MOVER_SPRINT_NAME "BotMover::Sprint/2"
#define AOWL_SYM_SAIN_MOVER_SPRINT_SECTION "il2cpp"
#define AOWL_SYM_SAIN_MOVER_SPRINT_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x30,0x0F,0xB6,0xFA,0x48,0x8B,0xD9

/* void Stop()
 *   BotMover::Stop/0
 *   RVA 0x01A2D600  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_SAIN_MOVER_STOP                0x01A2D600u
#define AOWL_SYM_SAIN_MOVER_STOP_ARITY 0
#define AOWL_SYM_SAIN_MOVER_STOP_OWNERS 1
#define AOWL_SYM_SAIN_MOVER_STOP_NAME "BotMover::Stop/0"
#define AOWL_SYM_SAIN_MOVER_STOP_SECTION "il2cpp"
#define AOWL_SYM_SAIN_MOVER_STOP_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x81,0x80,0x00,0x00,0x00,0xC6,0x81,0x38,0x01,0x00

/* void LookToPoint(Vector3 point)
 *   BotSteering::LookToPoint/1
 *   RVA 0x01A3B690  section il2cpp  owners 1  arity 1
 */
#define AOWL_SYM_SAIN_STEERING_LOOKTO           0x01A3B690u
#define AOWL_SYM_SAIN_STEERING_LOOKTO_ARITY 1
#define AOWL_SYM_SAIN_STEERING_LOOKTO_OWNERS 1
#define AOWL_SYM_SAIN_STEERING_LOOKTO_NAME "BotSteering::LookToPoint/1"
#define AOWL_SYM_SAIN_STEERING_LOOKTO_SECTION "il2cpp"
#define AOWL_SYM_SAIN_STEERING_LOOKTO_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x41,0x10,0x48,0x85,0xC0,0x74,0x3C,0x48,0x8B,0x40

/* bool Shoot()
 *   ShootData::Shoot/0
 *   RVA 0x01AF7940  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT           0x01AF7940u
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT_ARITY 0
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT_OWNERS 1
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT_NAME "ShootData::Shoot/0"
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT_SECTION "il2cpp"
#define AOWL_SYM_SAIN_SHOOTDATA_SHOOT_PROLOGUE 0x48,0x89,0x5C,0x24,0x20,0x57,0x48,0x83,0xEC,0x40,0x80,0x3D,0x0A,0x81,0x5C,0x05

/* void StopMove()
 *   EFT.BotOwner::StopMove/0
 *   RVA 0x0081C970  section il2cpp  owners 1  arity 0
 */
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE         0x0081C970u
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_ARITY 0
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_OWNERS 1
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_NAME "EFT.BotOwner::StopMove/0"
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_SECTION "il2cpp"
#define AOWL_SYM_SAIN_BOTOWNER_STOPMOVE_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x81,0xD0,0x03,0x00,0x00,0x48,0x85,0xC0,0x74,0x30

/* bool SamplePosition(Vector3 sourcePosition, NavMeshHit hit, float maxDistance, int areaMask)
 *   UnityEngine.AI.NavMesh::SamplePosition/4
 *   RVA 0x05238930  section il2cpp  owners 1  arity 4
 */
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE            0x05238930u
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE_ARITY 4
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE_OWNERS 1
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE_NAME "UnityEngine.AI.NavMesh::SamplePosition/4"
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE_SECTION "il2cpp"
#define AOWL_SYM_SAIN_NAVMESH_SAMPLE_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x30,0x48

/* ---- CALL ONLY. Deliberately spelled AOWL_SYMC_, not AOWL_SYM_.
 * There is no AOWL_SYM_ form of these, so a detour site cannot
 * reach one by accident -- it has to be typed on purpose, and
 * abi/aowlspt_symbols.txt has to carry a written reason. ------- */

/* GameObject get_gameObject()
 *   UnityEngine.Component::get_gameObject/0
 *   RVA 0x011F57E0  section il2cpp  owners 52  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 52 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_COMPONENT_GET_GAMEOBJECT. Declared why: 52 owners: every Component subclass folds to this one two-instruction body. Reading a GameObject off a Component we already hold is correct for whatever the receiver is; a detour here would fire for the whole engine.
 */
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT       0x011F57E0u
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT_ARITY 0
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT_OWNERS 52
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT_NAME "UnityEngine.Component::get_gameObject/0"
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT_SECTION "il2cpp"
#define AOWL_SYMC_COMPONENT_GET_GAMEOBJECT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xFB,0xEC,0xED,0x05,0x48,0x8B,0xD9

/* Transform get_transform()
 *   UnityEngine.Component::get_transform/0
 *   RVA 0x0073B0F0  section il2cpp  owners 15  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 15 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_COMPONENT_GET_TRANSFORM. Declared why: 15 owners, same folded accessor shape as get_gameObject. Call-only for the same reason.
 */
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM        0x0073B0F0u
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM_ARITY 0
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM_OWNERS 15
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM_NAME "UnityEngine.Component::get_transform/0"
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM_SECTION "il2cpp"
#define AOWL_SYMC_COMPONENT_GET_TRANSFORM_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xE3,0x93,0x99,0x06,0x48,0x8B,0xD9

/* void set_enabled(bool value)
 *   UnityEngine.Behaviour::set_enabled/1
 *   RVA 0x00C4C760  section il2cpp  owners 32  arity 1
 *   SHARED-CALL ESCAPE HATCH -- 32 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_BEHAVIOUR_SET_ENABLED. Declared why: 32 owners. Enabling the Behaviour instance we are holding is correct code; detouring it would intercept every enable in the process.
 */
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED          0x00C4C760u
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED_ARITY 1
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED_OWNERS 32
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED_NAME "UnityEngine.Behaviour::set_enabled/1"
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED_SECTION "il2cpp"
#define AOWL_SYMC_BEHAVIOUR_SET_ENABLED_PROLOGUE 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x4F,0x7D,0x48

/* Transform get_root()
 *   UnityEngine.Transform::get_root/0
 *   RVA 0x052B9C50  section il2cpp  owners 2  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 2 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_TF_GET_ROOT. Declared why: 2 owners. Walking up from a live Transform to its Canvas root is the debug overlay parenting step, and the receiver decides the answer.
 */
#define AOWL_SYMC_TF_GET_ROOT                    0x052B9C50u
#define AOWL_SYMC_TF_GET_ROOT_ARITY 0
#define AOWL_SYMC_TF_GET_ROOT_OWNERS 2
#define AOWL_SYMC_TF_GET_ROOT_NAME "UnityEngine.Transform::get_root/0"
#define AOWL_SYMC_TF_GET_ROOT_SECTION "il2cpp"
#define AOWL_SYMC_TF_GET_ROOT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0x4B,0xAF,0xE1,0x01,0x48,0x8B,0xD9

/* int get_width()
 *   UnityEngine.Screen::get_width/0
 *   RVA 0x0501B760  section il2cpp  owners 2  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 2 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_SCREEN_GET_WIDTH. Declared why: 2 owners, a static with no receiver at all. Reading the backbuffer width cannot be wrong for a caller; only a detour could be.
 */
#define AOWL_SYMC_SCREEN_GET_WIDTH               0x0501B760u
#define AOWL_SYMC_SCREEN_GET_WIDTH_ARITY 0
#define AOWL_SYMC_SCREEN_GET_WIDTH_OWNERS 2
#define AOWL_SYMC_SCREEN_GET_WIDTH_NAME "UnityEngine.Screen::get_width/0"
#define AOWL_SYMC_SCREEN_GET_WIDTH_SECTION "il2cpp"
#define AOWL_SYMC_SCREEN_GET_WIDTH_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x9D,0x78,0x0B,0x02,0x48,0x85,0xC0,0x75,0x18

/* int get_height()
 *   UnityEngine.Screen::get_height/0
 *   RVA 0x0501B7B0  section il2cpp  owners 2  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 2 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_SCREEN_GET_HEIGHT. Declared why: 2 owners, static, exactly as get_width. Used together with it for the overlay layout.
 */
#define AOWL_SYMC_SCREEN_GET_HEIGHT              0x0501B7B0u
#define AOWL_SYMC_SCREEN_GET_HEIGHT_ARITY 0
#define AOWL_SYMC_SCREEN_GET_HEIGHT_OWNERS 2
#define AOWL_SYMC_SCREEN_GET_HEIGHT_NAME "UnityEngine.Screen::get_height/0"
#define AOWL_SYMC_SCREEN_GET_HEIGHT_SECTION "il2cpp"
#define AOWL_SYMC_SCREEN_GET_HEIGHT_PROLOGUE 0x48,0x83,0xEC,0x28,0x48,0x8B,0x05,0x55,0x78,0x0B,0x02,0x48,0x85,0xC0,0x75,0x18

/* Transform get_parent()
 *   UnityEngine.Transform::get_parent/0
 *   RVA 0x052B81D0  section il2cpp  owners 3  arity 0
 *   SHARED-CALL ESCAPE HATCH -- 3 method definitions share this
 *   address. Calling it is correct code for the receiver you
 *   pass. DETOURING it is not, which is why there is no
 *   AOWL_SYM_TF_GET_PARENT. Declared why: 3 owners -- the generator caught this one; it was written as a plain symbol first and rejected. Walking up from a live Transform is receiver-decided and safe to call.
 */
#define AOWL_SYMC_TF_GET_PARENT                  0x052B81D0u
#define AOWL_SYMC_TF_GET_PARENT_ARITY 0
#define AOWL_SYMC_TF_GET_PARENT_OWNERS 3
#define AOWL_SYMC_TF_GET_PARENT_NAME "UnityEngine.Transform::get_parent/0"
#define AOWL_SYMC_TF_GET_PARENT_SECTION "il2cpp"
#define AOWL_SYMC_TF_GET_PARENT_PROLOGUE 0x40,0x53,0x48,0x83,0xEC,0x20,0x48,0x8B,0x05,0xB3,0xC9,0xE1,0x01,0x48,0x8B,0xD9

/* ---- REJECTED. Each expands to an undefined identifier. ------- */

/* SAIN_PHYSICS_RAYCAST -> ambiguous_arity_star_has_multiple_overloads
 *   UnityEngine.Physics::Raycast/3 did not resolve to a unique code address
 */
#define AOWL_SYM_SAIN_PHYSICS_RAYCAST AOWL_SYMBOL_REJECTED__SAIN_PHYSICS_RAYCAST__ambiguous_arity_star_has_multiple_overloads
#define AOWL_SYMC_SAIN_PHYSICS_RAYCAST AOWL_SYMBOL_REJECTED__SAIN_PHYSICS_RAYCAST__ambiguous_arity_star_has_multiple_overloads

#endif /* AOWLSPT_SYMTAB_H */
