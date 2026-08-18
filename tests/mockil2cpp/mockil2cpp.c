/* mockil2cpp — a stand-in IL2CPP runtime, for testing the client host.
 *
 * The client host talks to Tarkov through Unity's IL2CPP C API. That API is
 * exported from `GameAssembly.dll`, and the real one cannot be started outside
 * the game: BSG ship `global-metadata.dat` encrypted and the runtime decrypts
 * it during `il2cpp_init`, which needs the game's own startup. So the host's
 * `resolve` and `call` paths had no way to be exercised.
 *
 * This is that way. It implements the same C ABI over a small hand-built type
 * universe and builds as `GameAssembly.dll`, so the host binds to it by exactly
 * the mechanism it uses in the game — `GetModuleHandleW("GameAssembly.dll")`,
 * then `GetProcAddress` for each entry point — and cannot tell the difference.
 *
 * What that does and does not establish is worth being precise about.
 *
 *   It DOES prove the host's own code is right: symbol resolution, the C
 *   trampolines, iterating a class's methods and fields, marshalling strings
 *   both ways, boxing arguments by declared parameter type, unboxing returns,
 *   thread attach, and the detour engine.
 *
 *   It does NOT prove BSG's implementation behaves the same. That gap is
 *   narrowed by `il2cppprobe`, which confirms against the real
 *   `GameAssembly.dll` that every entry point the host calls is actually
 *   exported there — so what is left unverified is semantics, not existence.
 *
 * The type universe is deliberately shaped like the one a client mod meets:
 * a corlib type, a Unity type with a property getter, and a game type with
 * fields and methods that take arguments.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#define MOCK_EXPORT __declspec(dllexport)

/* ------------------------------------------------------------------ *
 * The object model
 * ------------------------------------------------------------------ */

typedef struct MockClass MockClass;
typedef struct MockMethod MockMethod;

/* Every managed object starts with a pointer to its class, which is what
 * `il2cpp_object_get_class` reads. Keeping that true here means the host's
 * unboxing path is exercised rather than special-cased. */
typedef struct MockObject {
    MockClass* klass;
} MockObject;

typedef struct MockString {
    MockClass* klass;
    int32_t    length;
    uint16_t   chars[512];
} MockString;

typedef struct MockBoxed {
    MockClass* klass;
    int64_t    value;
    float      fvalue;
} MockBoxed;

typedef struct MockField {
    const char* name;
    int32_t     offset;
    const char* typeName;
} MockField;

/* `impl` receives the instance (or NULL) and the same `void**` argument array
 * IL2CPP would hand a real method: a pointer to the value for value types, the
 * object pointer itself for reference types. */
typedef void* (*MockInvoke)(void* obj, void** params);

/* `methodPointer` is deliberately the first field, because it is the first
 * field of IL2CPP's real `MethodInfo` and the host reads it by that offset --
 * there is no accessor for it in the C API. A mock that put it elsewhere would
 * make the host look broken when it is the mock that is unfaithful. */
struct MockMethod {
    void*       methodPointer;
    const char* name;
    uint32_t    paramCount;
    const char* paramTypes[4];
    const char* returnType;
    MockInvoke  impl;
    MockClass*  klass;
    /* Whether the method is static. `il2cpp_method_get_flags` reports 0x10 for
     * these, and the host needs it: a compiled instance method takes `this` in
     * the first argument register and a static one does not, so a mock that got
     * this wrong would shift every decoded argument by one. */
    int32_t     isStatic;
    /* The *compiled* function, when the method has one.
     *
     * `methodPointer` in real IL2CPP is the compiled native function, with the
     * signature `(this, a, b, ..., MethodInfo*)`; `runtime_invoke` goes through
     * a per-signature invoker that unpacks the boxed argument array and calls
     * it. Everywhere else in this mock the two are conflated -- `methodPointer`
     * is set to the invoker -- which is harmless for calling and useless for
     * *detouring*, because a detour on an invoker sees an argument array rather
     * than arguments. Where a method sets `native`, the mock is faithful:
     * `methodPointer` is the native function and `impl` unpacks into it. */
    void*       native;
};

struct MockClass {
    const char* ns;
    const char* name;
    MockClass*  parent;
    int32_t     instanceSize;
    int32_t     isValueType;
    MockMethod* methods;
    int32_t     methodCount;
    MockField*  fields;
    int32_t     fieldCount;
};

typedef struct MockImage {
    const char* name;
    MockClass** classes;
    int32_t     classCount;
} MockImage;

typedef struct MockAssembly {
    MockImage* image;
} MockAssembly;

/* ------------------------------------------------------------------ *
 * String helpers
 * ------------------------------------------------------------------ */

static MockClass g_stringClass;

static MockString* mock_string_from(const char* s) {
    MockString* m = (MockString*)calloc(1, sizeof(MockString));
    if (!m) return NULL;
    m->klass = &g_stringClass;
    int32_t n = 0;
    while (s && s[n] && n < 511) {
        m->chars[n] = (uint16_t)(uint8_t)s[n];
        n++;
    }
    m->length = n;
    return m;
}

/* ------------------------------------------------------------------ *
 * The methods behind the type universe
 * ------------------------------------------------------------------ */

static MockClass g_int32Class;
static MockClass g_singleClass;
static MockClass g_boolClass;

static void* mock_box_i64(int64_t v) {
    MockBoxed* b = (MockBoxed*)calloc(1, sizeof(MockBoxed));
    if (!b) return NULL;
    b->klass = &g_int32Class;
    b->value = v;
    return b;
}
static void* mock_box_f32(float v) {
    MockBoxed* b = (MockBoxed*)calloc(1, sizeof(MockBoxed));
    if (!b) return NULL;
    b->klass = &g_singleClass;
    b->fvalue = v;
    b->value = 0;
    return b;
}
static void* mock_box_bool(int32_t v) {
    MockBoxed* b = (MockBoxed*)calloc(1, sizeof(MockBoxed));
    if (!b) return NULL;
    b->klass = &g_boolClass;
    b->value = v ? 1 : 0;
    return b;
}

/* UnityEngine.Application::get_unityVersion() -> string */
static void* m_unityVersion(void* obj, void** params) {
    (void)obj; (void)params;
    return mock_string_from("2022.3.43f2 (mock)");
}

/* EFT.Player::GetName() -> string */
static void* m_playerGetName(void* obj, void** params) {
    (void)obj; (void)params;
    return mock_string_from("Nikita");
}

/* EFT.Player::Add(System.Int32, System.Int32) -> System.Int32
 * The one that proves arguments actually arrive, in order, with the right
 * types. A host that dropped or reordered them would return the wrong sum
 * rather than failing, which is why the test asserts on the value. */
static void* m_playerAdd(void* obj, void** params) {
    (void)obj;
    int32_t a = *(int32_t*)params[0];
    int32_t b = *(int32_t*)params[1];
    return mock_box_i64((int64_t)(a + b));
}

/* EFT.Player::Greet(System.String) -> System.String */
static void* m_playerGreet(void* obj, void** params) {
    (void)obj;
    MockString* in = (MockString*)params[0];
    char buf[600];
    int32_t n = in ? in->length : 0;
    if (n > 500) n = 500;
    memcpy(buf, "hello ", 6);
    for (int32_t i = 0; i < n; i++) buf[6 + i] = (char)in->chars[i];
    buf[6 + n] = 0;
    return mock_string_from(buf);
}

/* EFT.Player::Scale(System.Single) -> System.Single */
static void* m_playerScale(void* obj, void** params) {
    (void)obj;
    float f = *(float*)params[0];
    return mock_box_f32(f * 2.0f);
}

/* EFT.Player::SetFlag(System.Boolean) -> System.Boolean */
static void* m_playerSetFlag(void* obj, void** params) {
    (void)obj;
    int32_t b = *(int32_t*)params[0];
    return mock_box_bool(!b);
}

/* EFT.Player::Tick() -> void. The detour target: something with no arguments
 * and no return, so a test can hook it and observe only the side effect. */
static int32_t g_tickCount = 0;
static void* m_playerTick(void* obj, void** params) {
    (void)obj; (void)params;
    g_tickCount++;
    return NULL;
}

MOCK_EXPORT int32_t mock_tick_count(void) { return g_tickCount; }

/* Live objects.
 *
 * Everything above is static: a method that needs no `this`. The interesting
 * half of a real game is not -- it is *this* player's health, reached from
 * *this* world -- and a host that can only call static members can reach none
 * of it. So the mock grows two singletons and an instance method that mutates
 * one, because the only way to prove a host passed the right `this` is to
 * change something on it and read it back.
 */
static MockClass g_gameWorldClass;
static MockClass g_playerClass;

/* Laid out to match `g_playerFields` exactly -- Health at 16, Level at 20 --
 * because a field read goes through `il2cpp_field_get_offset` and a mock whose
 * struct disagrees with its own metadata tests nothing. The padding is there to
 * make the offsets real rather than to make the numbers look tidy. */
typedef struct MockPlayer {
    MockClass* klass;   /* 0  */
    void*      pad;     /* 8  */
    float      health;  /* 16 */
    int32_t    level;   /* 20 */
} MockPlayer;

typedef struct MockWorld {
    MockClass*  klass;
    MockPlayer* mainPlayer;
} MockWorld;

static MockPlayer* g_thePlayer = NULL;
static MockWorld*  g_theWorld = NULL;

static MockPlayer* mock_player(void) {
    if (!g_thePlayer) {
        g_thePlayer = (MockPlayer*)calloc(1, sizeof(MockPlayer));
        g_thePlayer->klass = &g_playerClass;
        g_thePlayer->health = 100.0f;
        g_thePlayer->level = 1;
    }
    return g_thePlayer;
}

/* EFT.GameWorld::get_Instance() -> EFT.GameWorld  (static) */
static void* m_worldInstance(void* obj, void** params) {
    (void)obj; (void)params;
    if (!g_theWorld) {
        g_theWorld = (MockWorld*)calloc(1, sizeof(MockWorld));
        g_theWorld->klass = &g_gameWorldClass;
        g_theWorld->mainPlayer = mock_player();
    }
    return g_theWorld;
}

/* EFT.GameWorld::get_MainPlayer() -> EFT.Player  (instance) */
static void* m_worldMainPlayer(void* obj, void** params) {
    (void)params;
    if (!obj) return NULL;
    return ((MockWorld*)obj)->mainPlayer;
}

/* EFT.Player::get_Health() -> System.Single  (instance) */
static void* m_playerGetHealth(void* obj, void** params) {
    (void)params;
    if (!obj) return NULL;
    return mock_box_f32(((MockPlayer*)obj)->health);
}

/* EFT.Player::Damage(System.Single) -> System.Single  (instance)
 *
 * The proof. It subtracts from *this* player and returns what is left, so a
 * host that called it with the wrong `this` -- or with none -- returns a value
 * that cannot be confused with the right one. */
static void* m_playerDamage(void* obj, void** params) {
    if (!obj) return NULL;
    float amount = *(float*)params[0];
    MockPlayer* p = (MockPlayer*)obj;
    p->health -= amount;
    return mock_box_f32(p->health);
}

MOCK_EXPORT float mock_player_health(void) { return mock_player()->health; }

/* EFT.Player::Hurt(System.Single, System.Int32) -> System.Single
 *
 * Written with the signature a *compiled* IL2CPP method has, because it is the
 * one the detour path sees: `this` in RCX, the float in XMM1, the int in R8,
 * and the trailing MethodInfo* in R9. A host that decoded the arguments by
 * counting integer and float registers separately -- rather than by position --
 * would read the float out of XMM0 and get `this` reinterpreted as a double.
 * That is the mistake this method exists to catch. */
static float mock_native_hurt(void* thisPtr, float amount, int32_t kind,
                              void* methodInfo) {
    /* No null check, deliberately.
     *
     * A `if (!thisPtr) return 0;` compiles to a conditional branch inside the
     * first fourteen bytes, and the detour engine refuses to relocate a
     * relative branch out of a prologue -- correctly, since the target would
     * move. Real game methods have long prologues and this one has to as well
     * to be a useful stand-in. The mock is only ever called with a real
     * object. */
    (void)methodInfo;
    MockPlayer* p = (MockPlayer*)thisPtr;
    p->health -= amount * (float)kind;
    return p->health;
}

/* The invoker `runtime_invoke` uses: unpack the boxed array, call the compiled
 * function, box the result. Exactly what IL2CPP generates per signature. */
static void* m_playerHurt(void* obj, void** params) {
    float amount = *(float*)params[0];
    int32_t kind = *(int32_t*)params[1];
    return mock_box_f32(mock_native_hurt(obj, amount, kind, NULL));
}

/* EFT.Player::Boost(System.Single) -> System.Single, **static** and compiled.
 *
 * The suppression test patches this one. Static on purpose: with no `this`,
 * argument 0 is the float itself, so a host that assumed an instance would read
 * the wrong register and any replaced value would be right for the wrong
 * reason.
 *
 * It must be a *compiled* method rather than an invoker, and that distinction
 * is what this pair exists to enforce. Suppressing a detour on an invoker
 * returns the replacement where `runtime_invoke` expects a boxed object, and
 * the caller dereferences a float as a pointer -- which is a segfault, and was
 * one, before the mock grew `native`. Detouring the compiled function instead
 * puts the replacement in XMM0 where the invoker boxes it, exactly as it would
 * in the game. */
static int32_t g_boostCalls = 0;
static float mock_native_boost(float amount, void* methodInfo) {
    (void)methodInfo;
    g_boostCalls++;
    return amount * 3.0f;
}
static void* m_playerBoost(void* obj, void** params) {
    (void)obj;
    return mock_box_f32(mock_native_boost(*(float*)params[0], NULL));
}

/* How many times the original ran. A suppressed call must leave this alone --
 * which is the only way to tell "replaced the result" from "ran and then had
 * its result overwritten", and those are very different things. */
MOCK_EXPORT int32_t mock_boost_calls(void) { return g_boostCalls; }

/* ------------------------------------------------------------------ *
 * The type universe
 * ------------------------------------------------------------------ */

static MockMethod g_appMethods[] = {
    { NULL, "get_unityVersion", 0, {0,0,0,0}, "System.String", m_unityVersion, NULL, 1, NULL },
};

static MockMethod g_playerMethods[] = {
    { NULL, "GetName", 0, {0,0,0,0},                           "System.String",  m_playerGetName, NULL, 1, NULL },
    { NULL, "Add",     2, {"System.Int32","System.Int32",0,0}, "System.Int32",   m_playerAdd,     NULL, 1, NULL },
    { NULL, "Greet",   1, {"System.String",0,0,0},             "System.String",  m_playerGreet,   NULL, 1, NULL },
    { NULL, "Scale",   1, {"System.Single",0,0,0},             "System.Single",  m_playerScale,   NULL, 1, NULL },
    { NULL, "SetFlag", 1, {"System.Boolean",0,0,0},            "System.Boolean", m_playerSetFlag, NULL, 1, NULL },
    { NULL, "Tick",    0, {0,0,0,0},                           "System.Void",    m_playerTick,    NULL, 1, NULL },
    { NULL, "get_Health", 0, {0,0,0,0},                        "System.Single",  m_playerGetHealth, NULL, 0, NULL },
    { NULL, "Damage",  1, {"System.Single",0,0,0},             "System.Single",  m_playerDamage,  NULL, 0, NULL },
    { NULL, "Hurt",    2, {"System.Single","System.Int32",0,0},"System.Single",  m_playerHurt,    NULL, 0,
      (void*)mock_native_hurt },
    { NULL, "Boost",   1, {"System.Single",0,0,0},             "System.Single",  m_playerBoost,   NULL, 1,
      (void*)mock_native_boost },
};

static MockMethod g_worldMethods[] = {
    { NULL, "get_Instance",   0, {0,0,0,0}, "EFT.GameWorld", m_worldInstance,   NULL, 1, NULL },
    { NULL, "get_MainPlayer", 0, {0,0,0,0}, "EFT.Player",    m_worldMainPlayer, NULL, 0, NULL },
};

static MockField g_playerFields[] = {
    { "Health",  16, "System.Single" },
    { "Level",   20, "System.Int32"  },
    { "Nickname",24, "System.String" },
};

static MockClass g_objectClass  = { "System", "Object", NULL, 16, 0, NULL, 0, NULL, 0 };
static MockClass g_stringClass  = { "System", "String", &g_objectClass, 24, 0, NULL, 0, NULL, 0 };
static MockClass g_int32Class   = { "System", "Int32",  &g_objectClass, 4,  1, NULL, 0, NULL, 0 };
static MockClass g_singleClass  = { "System", "Single", &g_objectClass, 4,  1, NULL, 0, NULL, 0 };
static MockClass g_boolClass    = { "System", "Boolean",&g_objectClass, 1,  1, NULL, 0, NULL, 0 };
static MockClass g_voidClass    = { "System", "Void",   &g_objectClass, 0,  1, NULL, 0, NULL, 0 };

static MockClass g_appClass = {
    "UnityEngine", "Application", &g_objectClass, 16, 0,
    g_appMethods, 1, NULL, 0
};
static MockClass g_playerClass = {
    "EFT", "Player", &g_objectClass, 64, 0,
    g_playerMethods, 10, g_playerFields, 3
};
static MockClass g_gameWorldClass = {
    "EFT", "GameWorld", &g_objectClass, 32, 0,
    g_worldMethods, 2, NULL, 0
};

static MockClass* g_corlibClasses[] = {
    &g_objectClass, &g_stringClass, &g_int32Class,
    &g_singleClass, &g_boolClass, &g_voidClass
};
static MockClass* g_unityClasses[] = { &g_appClass };
static MockClass* g_eftClasses[]   = { &g_playerClass, &g_gameWorldClass };

static MockImage g_corlibImage = { "mscorlib.dll",       g_corlibClasses, 6 };
static MockImage g_unityImage  = { "UnityEngine.dll",    g_unityClasses,  1 };
static MockImage g_eftImage    = { "Assembly-CSharp.dll",g_eftClasses,    2 };

static MockAssembly g_assemblies[] = {
    { &g_corlibImage }, { &g_unityImage }, { &g_eftImage }
};
static void* g_assemblyPtrs[3];

static int  g_initialised = 0;
static char g_domain[8] = "mock";

/* Walks the type universe rather than naming each method table with a count.
 *
 * It used to be a loop per class with the count written in by hand, and adding
 * a method to a class left `methodPointer` NULL on the ones past the old count
 * -- which `il2cpp_runtime_invoke` reads, so the method resolved, invoked, and
 * returned NULL. That looks exactly like a method that legitimately returns
 * null, and it cost an hour. Derived from the tables now, so there is one place
 * to be wrong and it is the table itself. */
static void mock_wire(void) {
    for (int a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (int c = 0; c < img->classCount; c++) {
            MockClass* k = img->classes[c];
            for (int m = 0; m < k->methodCount; m++) {
                k->methods[m].klass = k;
                /* The compiled function when the method has one, the invoker
                 * otherwise. Detouring an invoker would see an argument array
                 * where the arguments should be, which is exactly the thing the
                 * argument-decoding tests need to be able to distinguish. */
                k->methods[m].methodPointer = k->methods[m].native
                    ? k->methods[m].native
                    : (void*)k->methods[m].impl;
            }
        }
    }
    for (int i = 0; i < 3; i++) g_assemblyPtrs[i] = &g_assemblies[i];
}

/* ------------------------------------------------------------------ *
 * The IL2CPP C API
 * ------------------------------------------------------------------ */

MOCK_EXPORT void il2cpp_set_data_dir(const char* dir) { (void)dir; }
MOCK_EXPORT void il2cpp_set_config_dir(const char* dir) { (void)dir; }

MOCK_EXPORT void* il2cpp_init(const char* name) {
    (void)name;
    mock_wire();
    g_initialised = 1;
    return g_domain;
}
MOCK_EXPORT void il2cpp_shutdown(void) { g_initialised = 0; }

/* The host polls this until it is non-NULL, exactly as it does against the
 * real runtime, so the mock stays un-initialised until `il2cpp_init` — the
 * same "module present but runtime not up yet" window the game has. */
MOCK_EXPORT void* il2cpp_domain_get(void) {
    return g_initialised ? (void*)g_domain : NULL;
}

MOCK_EXPORT void** il2cpp_domain_get_assemblies(void* domain, size_t* count) {
    (void)domain;
    if (count) *count = 3;
    return g_assemblyPtrs;
}
MOCK_EXPORT void* il2cpp_assembly_get_image(void* a) {
    return a ? ((MockAssembly*)a)->image : NULL;
}
MOCK_EXPORT const char* il2cpp_image_get_name(void* i) {
    return i ? ((MockImage*)i)->name : "";
}
MOCK_EXPORT size_t il2cpp_image_get_class_count(void* i) {
    return i ? (size_t)((MockImage*)i)->classCount : 0;
}
MOCK_EXPORT void* il2cpp_image_get_class(void* i, size_t index) {
    MockImage* im = (MockImage*)i;
    if (!im || (int32_t)index >= im->classCount) return NULL;
    return im->classes[index];
}

MOCK_EXPORT void* il2cpp_class_from_name(void* image, const char* ns, const char* name) {
    MockImage* im = (MockImage*)image;
    if (!im) return NULL;
    for (int32_t i = 0; i < im->classCount; i++) {
        MockClass* c = im->classes[i];
        const char* cns = c->ns ? c->ns : "";
        const char* n = ns ? ns : "";
        if (strcmp(cns, n) == 0 && strcmp(c->name, name) == 0) return c;
    }
    return NULL;
}

MOCK_EXPORT const char* il2cpp_class_get_name(void* c) {
    return c ? ((MockClass*)c)->name : "";
}
MOCK_EXPORT const char* il2cpp_class_get_namespace(void* c) {
    return c ? ((MockClass*)c)->ns : "";
}
MOCK_EXPORT void* il2cpp_class_get_parent(void* c) {
    return c ? ((MockClass*)c)->parent : NULL;
}
MOCK_EXPORT int32_t il2cpp_class_instance_size(void* c) {
    return c ? ((MockClass*)c)->instanceSize : 0;
}
MOCK_EXPORT int32_t il2cpp_class_is_valuetype(void* c) {
    return c ? ((MockClass*)c)->isValueType : 0;
}
MOCK_EXPORT void il2cpp_runtime_class_init(void* c) { (void)c; }
MOCK_EXPORT void* il2cpp_class_get_type(void* c) { return c; }

/* The iterator convention: `*iter` starts NULL and is advanced by the callee.
 * Storing the next index in the pointer itself is what the real runtime does
 * in spirit, and it means the host's cursor handling is exercised. */
MOCK_EXPORT void* il2cpp_class_get_methods(void* c, void** iter) {
    MockClass* k = (MockClass*)c;
    if (!k || !iter) return NULL;
    size_t i = (size_t)*iter;
    if ((int32_t)i >= k->methodCount) return NULL;
    *iter = (void*)(i + 1);
    return &k->methods[i];
}
MOCK_EXPORT void* il2cpp_class_get_fields(void* c, void** iter) {
    MockClass* k = (MockClass*)c;
    if (!k || !iter) return NULL;
    size_t i = (size_t)*iter;
    if ((int32_t)i >= k->fieldCount) return NULL;
    *iter = (void*)(i + 1);
    return &k->fields[i];
}
MOCK_EXPORT void* il2cpp_class_get_properties(void* c, void** iter) {
    (void)c; (void)iter; return NULL;
}

MOCK_EXPORT void* il2cpp_class_get_method_from_name(void* c, const char* name, int argc) {
    MockClass* k = (MockClass*)c;
    if (!k) return NULL;
    for (int32_t i = 0; i < k->methodCount; i++) {
        if (strcmp(k->methods[i].name, name) != 0) continue;
        if (argc >= 0 && (uint32_t)argc != k->methods[i].paramCount) continue;
        return &k->methods[i];
    }
    return NULL;
}
MOCK_EXPORT void* il2cpp_class_get_field_from_name(void* c, const char* name) {
    MockClass* k = (MockClass*)c;
    if (!k) return NULL;
    for (int32_t i = 0; i < k->fieldCount; i++)
        if (strcmp(k->fields[i].name, name) == 0) return &k->fields[i];
    return NULL;
}
MOCK_EXPORT void* il2cpp_class_get_property_from_name(void* c, const char* n) {
    (void)c; (void)n; return NULL;
}

MOCK_EXPORT const char* il2cpp_method_get_name(void* m) {
    return m ? ((MockMethod*)m)->name : "";
}
MOCK_EXPORT uint32_t il2cpp_method_get_param_count(void* m) {
    return m ? ((MockMethod*)m)->paramCount : 0;
}
MOCK_EXPORT void* il2cpp_method_get_class(void* m) {
    return m ? ((MockMethod*)m)->klass : NULL;
}
/* Types are represented by their name string, which is all the host uses them
 * for: deciding how to box an argument and how to read a return value. */
MOCK_EXPORT void* il2cpp_method_get_return_type(void* m) {
    return m ? (void*)((MockMethod*)m)->returnType : NULL;
}
MOCK_EXPORT void* il2cpp_method_get_param(void* m, uint32_t i) {
    MockMethod* mm = (MockMethod*)m;
    if (!mm || i >= mm->paramCount) return NULL;
    return (void*)mm->paramTypes[i];
}
MOCK_EXPORT uint32_t il2cpp_method_get_flags(void* m, uint32_t* iflags) {
    if (iflags) *iflags = 0;
    if (!m) return 0;
    /* 0x0010 is METHOD_ATTRIBUTE_STATIC. Nothing else here is modelled. */
    return ((MockMethod*)m)->isStatic ? 0x0010u : 0u;
}

MOCK_EXPORT const char* il2cpp_field_get_name(void* f) {
    return f ? ((MockField*)f)->name : "";
}
MOCK_EXPORT size_t il2cpp_field_get_offset(void* f) {
    return f ? (size_t)((MockField*)f)->offset : 0;
}
MOCK_EXPORT void* il2cpp_field_get_type(void* f) {
    return f ? (void*)((MockField*)f)->typeName : NULL;
}
MOCK_EXPORT void il2cpp_field_get_value(void* o, void* f, void* out) {
    if (!o || !f || !out) return;
    memcpy(out, (char*)o + ((MockField*)f)->offset, 4);
}
MOCK_EXPORT void il2cpp_field_set_value(void* o, void* f, void* v) {
    if (!o || !f || !v) return;
    memcpy((char*)o + ((MockField*)f)->offset, v, 4);
}
MOCK_EXPORT void il2cpp_field_static_get_value(void* f, void* out) { (void)f; (void)out; }
MOCK_EXPORT void il2cpp_field_static_set_value(void* f, void* v) { (void)f; (void)v; }

MOCK_EXPORT const char* il2cpp_property_get_name(void* p) { (void)p; return ""; }
MOCK_EXPORT void* il2cpp_property_get_get_method(void* p) { (void)p; return NULL; }
MOCK_EXPORT void* il2cpp_property_get_set_method(void* p) { (void)p; return NULL; }

/* Dispatch through `methodPointer`, not through `impl`. That is what makes a
 * detour observable here the way it is in the real runtime: patching the
 * pointer changes what invoke calls. */
MOCK_EXPORT void* il2cpp_runtime_invoke(void* m, void* obj, void** params, void** exc) {
    if (exc) *exc = NULL;
    MockMethod* mm = (MockMethod*)m;
    if (!mm || !mm->methodPointer) return NULL;
    return ((MockInvoke)mm->methodPointer)(obj, params);
}

MOCK_EXPORT void* il2cpp_object_new(void* c) {
    MockClass* k = (MockClass*)c;
    if (!k) return NULL;
    int32_t size = k->instanceSize < 16 ? 16 : k->instanceSize;
    MockObject* o = (MockObject*)calloc(1, (size_t)size);
    if (o) o->klass = k;
    return o;
}
MOCK_EXPORT void il2cpp_runtime_object_init(void* o) { (void)o; }
MOCK_EXPORT void* il2cpp_object_get_class(void* o) {
    return o ? ((MockObject*)o)->klass : NULL;
}
MOCK_EXPORT void* il2cpp_value_box(void* c, void* data) {
    MockBoxed* b = (MockBoxed*)calloc(1, sizeof(MockBoxed));
    if (!b) return NULL;
    b->klass = (MockClass*)c;
    if (data) memcpy(&b->value, data, 4);
    return b;
}
MOCK_EXPORT void* il2cpp_object_unbox(void* o) {
    MockBoxed* b = (MockBoxed*)o;
    if (!b) return NULL;
    if (b->klass == &g_singleClass) return &b->fvalue;
    return &b->value;
}

MOCK_EXPORT void* il2cpp_string_new(const char* s) { return mock_string_from(s); }
MOCK_EXPORT uint16_t* il2cpp_string_chars(void* s) {
    return s ? ((MockString*)s)->chars : NULL;
}
MOCK_EXPORT int32_t il2cpp_string_length(void* s) {
    return s ? ((MockString*)s)->length : 0;
}

MOCK_EXPORT const char* il2cpp_type_get_name(void* t) {
    /* The host frees this, so it must come from the same allocator it uses. */
    const char* n = t ? (const char*)t : "System.Void";
    size_t len = strlen(n);
    char* copy = (char*)calloc(1, len + 1);
    if (copy) memcpy(copy, n, len);
    return copy;
}
MOCK_EXPORT void* il2cpp_type_get_object(void* t) { return t; }

static char g_thread[8] = "thr";
MOCK_EXPORT void* il2cpp_thread_attach(void* domain) { (void)domain; return g_thread; }
MOCK_EXPORT void il2cpp_thread_detach(void* t) { (void)t; }
MOCK_EXPORT void* il2cpp_thread_current(void) { return g_thread; }

#define MAX_HANDLES 256
static void* g_handles[MAX_HANDLES];
static uint32_t g_handleCount = 0;

MOCK_EXPORT uint32_t il2cpp_gchandle_new(void* o, int32_t pinned) {
    (void)pinned;
    if (g_handleCount >= MAX_HANDLES) return 0;
    g_handles[g_handleCount++] = o;
    return g_handleCount;
}
MOCK_EXPORT void* il2cpp_gchandle_get_target(uint32_t h) {
    if (h == 0 || h > g_handleCount) return NULL;
    return g_handles[h - 1];
}
MOCK_EXPORT void il2cpp_gchandle_free(uint32_t h) { (void)h; }

MOCK_EXPORT void il2cpp_free(void* p) { free(p); }
