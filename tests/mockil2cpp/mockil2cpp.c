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
#include <stdio.h>
#include <windows.h>

#define MOCK_EXPORT __declspec(dllexport)

/* ------------------------------------------------------------------ *
 * The object model
 * ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ *
 * ONE RULE, AND IT HAS BITTEN THREE TIMES
 *
 * A `MockMethod` row carries two function pointers, and which one a test
 * reaches decides whether the test means anything.
 *
 *   `impl`   -- the *invoker*: `void* f(void* obj, void** params)`, boxing its
 *               result. This is what `il2cpp_runtime_invoke` calls, and it is
 *               the right thing for the boxed path.
 *   `native` -- the *compiled* method, with the signature IL2CPP would give it:
 *               `this` first for an instance method, the declared arguments in
 *               their register classes, a trailing `MethodInfo*`, and the
 *               result in RAX or XMM0.
 *
 * `mock_wire` sets `methodPointer` to `native` when there is one and to the
 * invoker otherwise. So:
 *
 *   **A row with no `native` is reachable reflectively and by nothing else.**
 *   Binding it with `aowlspt/fast`, or detouring it, or handing it to a typed
 *   patch frame, tests the invoker rather than the method -- and does so
 *   *plausibly*, which is the whole problem. A bound call on an invoker-only
 *   row reads the boxed object's address as the return value: as a bool that
 *   is true about fifteen times in sixteen, because the allocator aligns, so
 *   one call passes and two hundred thousand show 6.25% wrong. As a float it
 *   is a pointer reinterpreted, which is a plausible number rather than a
 *   crash.
 *
 * So: **any row a test binds, detours or benchmarks must have a real `native`
 * body**, and that body must be long enough to hold a fourteen-byte jump.
 * `mock_uncompiled_count`/`mock_uncompiled_name` below report the rows that do
 * not, so a harness can print them and a test that means to bind one can
 * assert it rather than remember.
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
    /* Whether the field is static. `il2cpp_field_get_flags` reports 0x10 for
     * these, and it is the *only* honest way to know: a static field's offset
     * is into the class's static data block and an instance field's is into
     * the object, and the two ranges overlap freely. `Player::SpawnCount`
     * below is deliberately at offset 16, which is also `Player::Health`'s
     * offset, so a binding that guesses staticness from the offset reads a
     * float as an int and reports a number.
     *
     * Appended rather than inserted so every existing row's initialiser stays
     * correct and means what it says: not static. */
    int32_t     isStatic;
    /* The declaring class, filled in by `mock_wire` for the same reason
     * `MockMethod.klass` is: a `FieldInfo*` in real IL2CPP knows what it
     * belongs to, and `il2cpp_field_static_get_value` cannot find the static
     * block without it. */
    MockClass*  klass;
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
    /* Six, not four, so that a method with more declared parameters than
     * Win64 has argument registers can exist here at all. `Quint` below is
     * five, which is the only way to reach the host's stack-argument case for
     * a *static* method; `Step` is four, which reaches it for an instance one
     * because `this` takes the first register. A stand-in that cannot express
     * the shape cannot test it, and that case was untested for exactly that
     * reason. */
    const char* paramTypes[6];
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
    /* The class's static storage, which is what `il2cpp_class_get_static_field_data`
     * hands back and what a static field's offset is relative to. NULL for
     * every class that has no static field, which is all but one of them --
     * and the NULL is load-bearing: a binding must refuse a class whose static
     * block the runtime will not give it rather than add an offset to zero. */
    void*       staticData;
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

/* How many entries a table has, asked of the table.
 *
 * These counts were written out by hand, and a row added without touching its
 * count is invisible: the method simply is not there, the host reports "no such
 * method", and the test written against it reads as a correct refusal. That
 * cost an hour once. Nothing here counts by hand any more. */
#define MOCK_N(a) ((int32_t)(sizeof(a) / sizeof((a)[0])))

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
/* The compiled body behind `Tick`.
 *
 * The invoker below is 13 bytes -- one short of the 14-byte jump -- so hooking
 * it was refused, and the refusal was correct: stealing 14 bytes would run past
 * its `ret`. A real game method has a real prologue, and a stand-in whose
 * methods are all shorter than a jump silently stops testing the thing the
 * tests are about. This one has the length a compiled method has. */
static int32_t g_nativeTicks = 0;
static void mock_native_tick(void* thisPtr, void* methodInfo) {
    (void)thisPtr; (void)methodInfo;
    g_nativeTicks++;
    g_tickCount++;
}
MOCK_EXPORT int32_t mock_native_tick_count(void) { return g_nativeTicks; }

static void* m_playerTick(void* obj, void** params) {
    (void)params;
    mock_native_tick(obj, NULL);
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
static MockClass g_vec3Class;

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
 * function, box the result. Exactly what IL2CPP generates per signature.
 *
 * The call is **indirect, through `methodPointer`**, and that is the whole
 * point of the pair. Written as a direct `mock_native_hurt(...)` it was a call
 * gcc could see through: at -O1 it inlined the compiled function into the
 * invoker, so `runtime_invoke` ran a private copy and a detour on
 * `mock_native_hurt` fired for nobody. The test passed the value through
 * unchanged and looked like a working hook that simply chose not to intervene.
 * Real IL2CPP invokers take `methodPointer` as an argument and call it
 * indirectly for the same reason a detour has to work at all. */
static MockMethod* g_hurtMethod = NULL;
static MockMethod* g_boostMethod = NULL;

typedef float (*FnHurt)(void*, float, int32_t, void*);
typedef float (*FnBoost)(float, void*);

static void* m_playerHurt(void* obj, void** params) {
    float amount = *(float*)params[0];
    int32_t kind = *(int32_t*)params[1];
    FnHurt fn = (FnHurt)g_hurtMethod->methodPointer;
    return mock_box_f32(fn(obj, amount, kind, NULL));
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
 * the caller dereferences a float as a pointer -- which is a segfault.
 * Detouring the compiled function instead puts the replacement in XMM0 where
 * the invoker boxes it, exactly as it would in the game.
 *
 * Growing `native` was only half of that. The other half was `runtime_invoke`,
 * which went on calling `methodPointer` directly -- so once `methodPointer`
 * became the compiled function, invoke handed `(obj, params)` to something
 * whose signature is `(float, MethodInfo*)` and unboxed the returned float by
 * dereferencing it. The same segfault, one level along, and it looked like the
 * detour engine's because it only appeared when a suppression was in flight. */
static int32_t g_boostCalls = 0;
static float mock_native_boost(float amount, void* methodInfo) {
    (void)methodInfo;
    g_boostCalls++;
    return amount * 3.0f;
}
static void* m_playerBoost(void* obj, void** params) {
    (void)obj;
    FnBoost fn = (FnBoost)g_boostMethod->methodPointer;
    return mock_box_f32(fn(*(float*)params[0], NULL));
}

/* How many times the original ran. A suppressed call must leave this alone --
 * which is the only way to tell "replaced the result" from "ran and then had
 * its result overwritten", and those are very different things. */
MOCK_EXPORT int32_t mock_boost_calls(void) { return g_boostCalls; }

/* EFT.Player::Sensitivity(System.Single) -> System.Single, **static** and
 * compiled. The postfix target.
 *
 * It exists because a postfix can only be proved by a value the handler could
 * not have produced on its own. `Sensitivity` multiplies by 1.5 and the test's
 * handler doubles what it is given, so 4.0 must come back as 12.0 -- a number
 * that requires the original to have run *and* its result to have reached the
 * handler. A prefix that suppressed and answered would give the handler's own
 * number; a postfix that never saw the result would double nothing and give
 * 0.0. Neither is 12.0.
 *
 * Static, compiled, and one argument: two register slots plus the trailing
 * `MethodInfo*`, comfortably inside the four the postfix thunk can carry. */
static int32_t g_sensCalls = 0;
static float mock_native_sensitivity(float amount, void* methodInfo) {
    (void)methodInfo;
    g_sensCalls++;
    return amount * 1.5f;
}
static MockMethod* g_sensMethod = NULL;
typedef float (*FnSens)(float, void*);
static void* m_playerSensitivity(void* obj, void** params) {
    (void)obj;
    FnSens fn = (FnSens)g_sensMethod->methodPointer;
    return mock_box_f32(fn(*(float*)params[0], NULL));
}

/* How many times the original ran. A postfix must leave this *rising*: that is
 * the half of the assertion a suppressing prefix would fail. */
MOCK_EXPORT int32_t mock_sens_calls(void) { return g_sensCalls; }

/* EFT.Player::Ping(System.Single) -> System.Single, static and compiled.
 *
 * The same shape as `Sensitivity` and here only to be timed. A postfix comes in
 * two prices -- with the arguments and without -- and they are an order of
 * magnitude apart, because building the argument array is where a reference
 * costs a GC handle and a payload costs a string. A mod choosing between them
 * needs both numbers, and neither can be measured on a method that already has
 * a hook: the engine allows one detour per method. */
static int32_t g_pingCalls = 0;
static float mock_native_ping(float amount, void* methodInfo) {
    (void)methodInfo;
    g_pingCalls++;
    return amount + 1.0f;
}
static MockMethod* g_pingMethod = NULL;
static void* m_playerPing(void* obj, void** params) {
    (void)obj;
    FnSens fn = (FnSens)g_pingMethod->methodPointer;
    return mock_box_f32(fn(*(float*)params[0], NULL));
}
MOCK_EXPORT int32_t mock_ping_calls(void) { return g_pingCalls; }

/* EFT.Player::Sway(System.Single) -> System.Single, static and compiled.
 *
 * `Sensitivity`'s twin, and here for the same reason `Ping` is a twin of it:
 * the engine allows one detour per method, so proving the *typed* postfix
 * needs a method the JSON postfix is not already on. Same arithmetic as
 * `Sensitivity` -- multiply by 1.5 -- so the same single number proves it:
 * 4.0 in, 6.0 out of the original, 12.0 after a handler that doubles what it
 * was given. A typed postfix that read the return out of RAX instead of XMM0
 * would double register residue and answer something very large; one that
 * never saw the original would double zero. Neither is 12.0. */
static int32_t g_swayCalls = 0;
static float mock_native_sway(float amount, void* methodInfo) {
    (void)methodInfo;
    g_swayCalls++;
    return amount * 1.5f;
}
static MockMethod* g_swayMethod = NULL;
static void* m_playerSway(void* obj, void** params) {
    (void)obj;
    FnSens fn = (FnSens)g_swayMethod->methodPointer;
    return mock_box_f32(fn(*(float*)params[0], NULL));
}
/* Rising is half the assertion: a typed postfix must let the original run,
 * which is what separates it from a prefix that answered instead. */
MOCK_EXPORT int32_t mock_sway_calls(void) { return g_swayCalls; }

/* EFT.Player::Quint(Single, Int32, String, Single, Int32) -> System.Single,
 * **static** and compiled.
 *
 * Five declared parameters, which is one more than Win64 has argument
 * registers, and static so that parameter *n* lands in register position *n*.
 * So the first four are in registers -- and deliberately in both files:
 * `System.Single` at positions 0 and 3 is XMM0 and XMM3, `System.Int32` at 1
 * is RDX, and the string pointer at 2 is R8. A host that counted the two
 * register files separately would read the second float out of XMM1 and
 * report a number.
 *
 * The fifth travelled on the stack and the thunk did not save it. It exists to
 * be *named* rather than answered: `describeArgs` is what says so, and before
 * this method there was nothing in the stand-in that could reach that case for
 * a static method at all.
 *
 * No branches, and long enough to hold a fourteen-byte jump, for the reason
 * every other compiled stand-in here has neither. */
static int32_t g_quintCalls = 0;
static float mock_native_quint(float a, int32_t b, void* text, float d,
                               int32_t e, void* methodInfo) {
    (void)methodInfo; (void)text;
    g_quintCalls++;
    return a * 1000.0f + (float)b * 100.0f + d * 10.0f + (float)e;
}
static MockMethod* g_quintMethod = NULL;
typedef float (*FnQuint)(float, int32_t, void*, float, int32_t, void*);
static void* m_playerQuint(void* obj, void** params) {
    (void)obj;
    FnQuint fn = (FnQuint)g_quintMethod->methodPointer;
    return mock_box_f32(fn(*(float*)params[0], *(int32_t*)params[1], params[2],
                           *(float*)params[3], *(int32_t*)params[4], NULL));
}
/* How many times the original ran. A prefix that only reads the arguments must
 * leave this rising: a payload assertion against a method that never ran would
 * be an assertion about nothing. */
MOCK_EXPORT int32_t mock_quint_calls(void) { return g_quintCalls; }

/* EFT.Player::Wide(Int32, Int32, Int32, Int32) -> System.Int32, static.
 *
 * Here to be refused. Four declared arguments plus IL2CPP's trailing
 * `MethodInfo*` is five register slots, and Win64 passes the fifth on the
 * stack -- at a fixed offset from the rsp the method was entered with. A
 * postfix thunk calls the original from inside its own frame, so that offset
 * lands in the thunk's locals rather than on the argument. The host refuses a
 * postfix here, and a prefix on the same method still works, which is the
 * distinction the test pins. */
static void* m_playerWide(void* obj, void** params) {
    (void)obj;
    return mock_box_i64((int64_t)(*(int32_t*)params[0] + *(int32_t*)params[1] +
                                  *(int32_t*)params[2] + *(int32_t*)params[3]));
}

/* ------------------------------------------------------------------ *
 * Unity's per-frame update  (added for the main-thread drain)
 *
 * `invoke_main` is only worth its name if the host can get onto the thread
 * Unity runs its player loop on, and the way it does that is to detour a
 * managed method that loop calls once a frame. To test that, this mock needs
 * two things the rest of it has no reason to have: a method that plays the
 * part, and a thread that calls it the way the player loop would.
 *
 * The name is one of the host's real candidates rather than an invented one,
 * so the mock exercises the candidate list as written -- and deliberately not
 * the *first* candidate, so a run also proves the host falls through the ones
 * that are absent (`EFT.MainApplication`, which does not exist here) and the
 * ones whose class exists without the method (`EFT.GameWorld::Update`).
 *
 * The body is longer than it needs to be, and that is the point: a detour
 * replaces the first fourteen bytes of a function, so a one-line function is
 * refused for being shorter than its own prologue. Real per-frame methods are
 * not that short; this one must not be either or it would test a refusal
 * rather than a hook.
 * ------------------------------------------------------------------ */

static MockClass  g_frameClass;
static MockMethod* g_frameMethod = NULL;
static volatile LONG g_frameCount = 0;
static double g_frameTime = 0.0;
static double g_frameDelta = 1.0 / 60.0;

/* UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate() -> void, static and
 * compiled. Detoured, not invoked: the host hooks the compiled function, and
 * the thread below calls it through `methodPointer` for the same reason the
 * other compiled methods here do -- a direct call is one gcc inlines at -O1,
 * and a detour on an inlined body fires for nobody. */
static void mock_native_frame(void* methodInfo) {
    (void)methodInfo;
    g_frameTime += g_frameDelta;
    if (g_frameTime > 1.0e9) g_frameTime = 0.0;
    InterlockedIncrement(&g_frameCount);
}

typedef void (*FnFrame)(void*);

static void* m_framePerformUpdate(void* obj, void** params) {
    (void)obj; (void)params;
    FnFrame fn = (FnFrame)g_frameMethod->methodPointer;
    fn(NULL);
    return NULL;
}

/* ------------------------------------------------------------------ *
 * The type universe
 * ------------------------------------------------------------------ */

/* `UnityEngine.Application::targetFrameRate`  (added for `mods/perf`)
 *
 * Appended to the existing `Application` class rather than given one of its
 * own, because that really is where it lives and a mod resolving it by name
 * has to find it there. `get_unityVersion` is untouched and stays first.
 *
 * `g_knobWrites` counts every write through any of the settings this file
 * grew for `mods/perf`; it is declared here because this is the first thing
 * that touches it. */
static int32_t g_knobWrites = 0;
static int32_t g_appTargetFps = -1;

static void* m_appGetTargetFrameRate(void* obj, void** params) {
    (void)obj; (void)params;
    return mock_box_i64(g_appTargetFps);
}
static void* m_appSetTargetFrameRate(void* obj, void** params) {
    (void)obj;
    g_appTargetFps = *(int32_t*)params[0];
    g_knobWrites++;
    return NULL;
}

static MockMethod g_appMethods[] = {
    { NULL, "get_unityVersion", 0, {0,0,0,0}, "System.String", m_unityVersion, NULL, 1, NULL },
    { NULL, "get_targetFrameRate", 0, {0,0,0,0}, "System.Int32",
      m_appGetTargetFrameRate, NULL, 1, NULL },
    { NULL, "set_targetFrameRate", 1, {"System.Int32",0,0,0}, "System.Void",
      m_appSetTargetFrameRate, NULL, 1, NULL },
};

/* A `UnityEngine.Vector3` property, and the reason it is here.
 *
 * `aowlspt/fast` correctly refuses a 12-byte aggregate: it is not a register
 * class. Win64 passes and returns one through a hidden pointer instead, so the
 * compiled function for `Vector3 get_Position()` is really
 * `void* f(void* sret, void* this, MethodInfo*)`, and `mods/sain`'s `tryShaped`
 * asserts exactly that shape through `bindRaw`. That assertion is the sharpest
 * thing in the mod and until now it had nothing to run against offline: the
 * mock had no value type of a non-register size at all, so the shaped path was
 * never taken in any test and a mistake in it would have shown up first in
 * somebody's raid.
 *
 * `mock_native_get_position` is that compiled function, with the real shape.
 * `m_playerGetPosition` is the invoker `il2cpp_runtime_invoke` goes through,
 * which boxes -- so the *fallback* path is exercised by the same member. Both
 * halves of the branch, one row.
 *
 * The position lives in a static rather than on `MockPlayer`, because
 * `MockPlayer` is laid out to match `g_playerFields` exactly and adding three
 * floats to it would move a field whose offset another test reads. */
static float g_playerPos[3] = { 12.5f, 3.25f, -4.75f };

MOCK_EXPORT void mock_set_player_position(float x, float y, float z) {
    g_playerPos[0] = x; g_playerPos[1] = y; g_playerPos[2] = z;
}

static void* mock_native_get_position(void* sret, void* thisPtr,
                                      void* methodInfo) {
    (void)thisPtr; (void)methodInfo;
    if (sret) {
        float* out = (float*)sret;
        out[0] = g_playerPos[0];
        out[1] = g_playerPos[1];
        out[2] = g_playerPos[2];
    }
    return sret;
}

static void* m_playerGetPosition(void* obj, void** params) {
    (void)obj; (void)params;
    /* Boxed, the way `il2cpp_runtime_invoke` returns a value type. The payload
     * starts where `il2cpp_object_unbox` says it does, which for this mock is
     * `&b->value` -- twelve bytes fits inside `value` plus `fvalue`. */
    MockBoxed* b = (MockBoxed*)calloc(1, sizeof(MockBoxed));
    if (!b) return NULL;
    b->klass = &g_vec3Class;
    float* out = (float*)&b->value;
    out[0] = g_playerPos[0];
    out[1] = g_playerPos[1];
    out[2] = g_playerPos[2];
    return b;
}

/* A real compiled function, for the same reason `get_Position` has one.
 *
 * Everywhere the mock leaves `native` NULL it conflates `methodPointer` with
 * the *invoker*, which takes `(obj, void** params)` and returns a boxed value.
 * That is harmless for `il2cpp_runtime_invoke` and wrong for a bound call: a
 * trampoline that expects a bool in the return register gets the address of a
 * box instead, and reads its low byte -- which is nonzero fifteen times in
 * sixteen, because the allocator aligns. A test that calls it once passes; a
 * test that calls it two hundred thousand times finds 6.25% of them false, and
 * that is exactly how `mods/sain` found this.
 *
 * So this row is faithful: `methodPointer` is a function with the shape IL2CPP
 * compiles for `bool get_IsAI()`, and `impl` is the invoker that boxes. */
static int32_t mock_native_get_is_ai(void* thisPtr, void* methodInfo) {
    (void)thisPtr; (void)methodInfo;
    return 1;
}

static void* m_playerGetIsAI(void* obj, void** params) {
    (void)obj; (void)params;
    return mock_box_bool(mock_native_get_is_ai(obj, NULL));
}

static MockMethod g_playerMethods[] = {
    { NULL, "GetName", 0, {0,0,0,0},                           "System.String",  m_playerGetName, NULL, 1, NULL },
    { NULL, "Add",     2, {"System.Int32","System.Int32",0,0}, "System.Int32",   m_playerAdd,     NULL, 1, NULL },
    { NULL, "Greet",   1, {"System.String",0,0,0},             "System.String",  m_playerGreet,   NULL, 1, NULL },
    { NULL, "Scale",   1, {"System.Single",0,0,0},             "System.Single",  m_playerScale,   NULL, 1, NULL },
    { NULL, "SetFlag", 1, {"System.Boolean",0,0,0},            "System.Boolean", m_playerSetFlag, NULL, 1, NULL },
    { NULL, "Tick",    0, {0,0,0,0},                           "System.Void",    m_playerTick,    NULL, 1,
      (void*)mock_native_tick },
    { NULL, "get_Health", 0, {0,0,0,0},                        "System.Single",  m_playerGetHealth, NULL, 0, NULL },
    { NULL, "Damage",  1, {"System.Single",0,0,0},             "System.Single",  m_playerDamage,  NULL, 0, NULL },
    { NULL, "Hurt",    2, {"System.Single","System.Int32",0,0},"System.Single",  m_playerHurt,    NULL, 0,
      (void*)mock_native_hurt },
    { NULL, "Boost",   1, {"System.Single",0,0,0},             "System.Single",  m_playerBoost,   NULL, 1,
      (void*)mock_native_boost },
    { NULL, "Sensitivity", 1, {"System.Single",0,0,0},        "System.Single",  m_playerSensitivity, NULL, 1,
      (void*)mock_native_sensitivity },
    { NULL, "Ping",    1, {"System.Single",0,0,0},             "System.Single",  m_playerPing,    NULL, 1,
      (void*)mock_native_ping },
    { NULL, "Sway",    1, {"System.Single",0,0,0},             "System.Single",  m_playerSway,    NULL, 1,
      (void*)mock_native_sway },
    { NULL, "Wide",    4, {"System.Int32","System.Int32","System.Int32","System.Int32"},
                                                             "System.Int32",   m_playerWide,    NULL, 1, NULL },
    { NULL, "Quint",   5, {"System.Single","System.Int32","System.String",
                           "System.Single","System.Int32"},   "System.Single",  m_playerQuint,   NULL, 1,
      (void*)mock_native_quint },
    /* Added for `mods/sain`'s binding self-test: a bool the plain fast path
       takes, and a Vector3 only the shaped path can. */
    { (void*)mock_native_get_is_ai, "get_IsAI", 0, {0,0,0,0}, "System.Boolean",
      m_playerGetIsAI, NULL, 0, (void*)mock_native_get_is_ai },
    { (void*)mock_native_get_position, "get_Position", 0, {0,0,0,0},
      "UnityEngine.Vector3", m_playerGetPosition, NULL, 0,
      (void*)mock_native_get_position },
};

static MockMethod g_worldMethods[] = {
    { NULL, "get_Instance",   0, {0,0,0,0}, "EFT.GameWorld", m_worldInstance,   NULL, 1, NULL },
    { NULL, "get_MainPlayer", 0, {0,0,0,0}, "EFT.Player",    m_worldMainPlayer, NULL, 0, NULL },
};

/* EFT.Player's static storage.
 *
 * Laid out so that the static field's offset **collides with an instance
 * field's**: `SpawnCount` is a `System.Int32` at offset 16 of this block, and
 * `Health` is a `System.Single` at offset 16 of a Player object. A binding
 * that decides staticness by asking whether the offset falls inside the
 * instance size cannot tell them apart -- it reads a float's bits as an int
 * and answers with total confidence. That is the failure this block exists to
 * make reachable, and the reason `mock_player_spawn_count` is exported: the
 * *runtime's* view of the value is the only thing that can say whether a write
 * landed in the static block or in some object.
 *
 * This comment used to name the wrong answer as 1091567616, which is 9.0f and
 * is a value `health` never holds here: it is initialised to 100.0f
 * (0x42C80000, 1120403456) and every `Hurt` call moves it, so the wrong read
 * answers whatever the float happens to be at that moment reinterpreted. A
 * checker must therefore compare against the bits of the *live* float rather
 * than against a constant -- which is what `mods/classicmovement`'s guard does,
 * and it is why that guard is a real check and a hard-coded number would not
 * have been. */
static struct {
    unsigned char pad[16];
    int32_t       spawnCount;   /* offset 16 */
    float         spawnRate;    /* offset 20 */
} g_playerStatics = { { 0 }, 1337, 2.5f };

MOCK_EXPORT int32_t mock_player_spawn_count(void) {
    return g_playerStatics.spawnCount;
}
MOCK_EXPORT float mock_player_spawn_rate(void) {
    return g_playerStatics.spawnRate;
}

/* How many times the host asked for a class's static block. Exported for the
 * same reason `mock_wbarrier_calls` is: without it, a check that a static read
 * "worked" would pass just as happily against a binding that never called
 * `il2cpp_class_get_static_field_data` at all and read an object instead. */
static int32_t g_staticDataCalls = 0;
MOCK_EXPORT int32_t mock_static_field_data_calls(void) {
    return g_staticDataCalls;
}

static MockField g_playerFields[] = {
    { "Health",  16, "System.Single", 0 },
    { "Level",   20, "System.Int32" , 0 },
    { "Nickname",24, "System.String", 0 },
    /* Static, and at the same offset as `Health` on purpose. See above. */
    { "SpawnCount", 16, "System.Int32",  1 },
    { "SpawnRate",  20, "System.Single", 1 },
};

/* System.Object::GetType(), and why a stand-in needs it.
 *
 * `aowlspt/game`'s `alive()` is a `GetType` call: an object the collector has
 * taken cannot answer one, so a call that comes back `Ok` is the object saying
 * it is still there. Nothing in this universe implemented it, so `alive()`
 * answered *false about a plainly live object* -- and false is the one answer
 * a liveness predicate must never give by accident, because a mod acts on it.
 * The refusal came from the mock and read as a statement about the object.
 *
 * It returns a real `System.Type` instance -- an object with a class pointer
 * at offset 0, like every other object here -- rather than the `MockClass*`
 * itself. The host calls `il2cpp_object_get_class` on a reference return, and
 * handing it a `MockClass*` would have it read `ns` as a class pointer.
 *
 * The counter is the assertion's subject: "alive() said true" is worth nothing
 * unless the runtime agrees it was asked. */
typedef struct MockTypeObject {
    MockClass* klass;        /* System.Type */
    MockClass* represents;   /* the class this Type object stands for */
} MockTypeObject;

static MockClass g_typeClass;
#define MOCK_MAX_TYPEOBJS 64
static MockTypeObject g_typeObjects[MOCK_MAX_TYPEOBJS];
static int32_t g_typeObjectCount = 0;
static int32_t g_getTypeCalls = 0;

static void* m_objectGetType(void* obj, void** params) {
    (void)params;
    ++g_getTypeCalls;
    if (!obj) return NULL;
    MockClass* k = ((MockObject*)obj)->klass;
    for (int32_t i = 0; i < g_typeObjectCount; i++)
        if (g_typeObjects[i].represents == k) return &g_typeObjects[i];
    if (g_typeObjectCount >= MOCK_MAX_TYPEOBJS) return NULL;
    g_typeObjects[g_typeObjectCount].klass = &g_typeClass;
    g_typeObjects[g_typeObjectCount].represents = k;
    return &g_typeObjects[g_typeObjectCount++];
}

MOCK_EXPORT int32_t mock_gettype_calls(void) { return g_getTypeCalls; }

static MockMethod g_objectMethods[] = {
    { NULL, "GetType", 0, {0,0,0,0}, "System.Type", m_objectGetType, NULL, 0,
      NULL },
};

static MockClass g_objectClass  = { "System", "Object", NULL, 16, 0,
                                    g_objectMethods, MOCK_N(g_objectMethods),
                                    NULL, 0, NULL };
static MockClass g_typeClass    = { "System", "Type", &g_objectClass, 16, 0,
                                    NULL, 0, NULL, 0, NULL };
/* `System.Double` exists here for one reason: it is half of how a mod asks the
 * runtime what its value-type size convention is. `mods/sain`'s `headerBytes`
 * calibrates by taking `size(Int32) - 4`, which is only meaningful next to a
 * type of known different payload -- and without a `Double` in the universe the
 * calibration silently fell back to a constant of 16, which is right for
 * `GameAssembly.dll` and wrong for this mock, so every shaped binding was
 * refused for a bad size and the log said the shape had been checked. */
static MockClass g_doubleClass  = { "System", "Double", &g_objectClass, 8,  1, NULL, 0, NULL, 0 };
/* Twelve bytes: not a register class, so Win64 moves it through memory. This is
 * the type the shaped call path exists for. */
static MockClass g_vec3Class    = { "UnityEngine", "Vector3", &g_objectClass, 12, 1, NULL, 0, NULL, 0 };
static MockClass g_stringClass  = { "System", "String", &g_objectClass, 24, 0, NULL, 0, NULL, 0 };
static MockClass g_int32Class   = { "System", "Int32",  &g_objectClass, 4,  1, NULL, 0, NULL, 0 };
static MockClass g_singleClass  = { "System", "Single", &g_objectClass, 4,  1, NULL, 0, NULL, 0 };
static MockClass g_boolClass    = { "System", "Boolean",&g_objectClass, 1,  1, NULL, 0, NULL, 0 };
static MockClass g_voidClass    = { "System", "Void",   &g_objectClass, 0,  1, NULL, 0, NULL, 0 };

static MockClass g_appClass = {
    "UnityEngine", "Application", &g_objectClass, 16, 0,
    g_appMethods, MOCK_N(g_appMethods), NULL, 0
};
static MockClass g_playerClass = {
    "EFT", "Player", &g_objectClass, 64, 0,
    g_playerMethods, MOCK_N(g_playerMethods), g_playerFields, MOCK_N(g_playerFields),
    &g_playerStatics
};
static MockClass g_gameWorldClass = {
    "EFT", "GameWorld", &g_objectClass, 32, 0,
    g_worldMethods, MOCK_N(g_worldMethods), NULL, 0
};

/* The per-frame method's own table and class. Its namespace really does
 * contain a dot -- `UnityEngine.UI` -- which is worth having here: the host
 * splits a qualified name at the *last* dot, and a type universe where every
 * namespace is a single word would never have proved that. */
static MockMethod g_frameMethods[] = {
    { NULL, "PerformUpdate", 0, {0,0,0,0}, "System.Void", m_framePerformUpdate,
      NULL, 1, (void*)mock_native_frame },
};
static MockClass g_frameClass = {
    "UnityEngine.UI", "CanvasUpdateRegistry", &g_objectClass, 16, 0,
    g_frameMethods, MOCK_N(g_frameMethods), NULL, 0
};

/* ------------------------------------------------------------------ *
 * A movement context, an enum, and an instance  (added for `this` and for
 * value-type arguments)
 *
 * Two holes in the host were found against real mods and neither could be
 * reproduced here, because nothing in this universe had the shape:
 *
 *   A patched **instance** method's `this` was dropped. Every compiled method
 *   above that a test detours is static, so the omission was invisible.
 *   `SetTilt` is an instance method with one float argument: a handler that
 *   is not told `this` cannot say which context was tilted, which is exactly
 *   the failure two mods hit.
 *
 *   An **enum** argument was treated as a reference, and the host made a GC
 *   handle out of the integer. `ApplyCondition` takes one. `EPhysicalCondition`
 *   is a value type here, as it is in the game, so the host's classification
 *   path runs against a runtime that answers rather than against a name it
 *   happens to recognise.
 *
 * The private field is `_player`, spelled the way the game spells one, because
 * reaching a private field is most of what reflection is for here.
 * ------------------------------------------------------------------ */

static MockClass g_conditionClass;
static MockClass g_moveContextClass;

/* Laid out to match `g_contextFields` exactly. */
typedef struct MockMoveContext {
    MockClass*  klass;      /* 0  */
    MockPlayer* player;     /* 8  */
    float       tilt;       /* 16 */
    int32_t     condition;  /* 20 */
} MockMoveContext;

static MockMoveContext* g_theContext = NULL;

static MockMoveContext* mock_context(void) {
    if (!g_theContext) {
        g_theContext = (MockMoveContext*)calloc(1, sizeof(MockMoveContext));
        g_theContext->klass = &g_moveContextClass;
        g_theContext->player = mock_player();
        g_theContext->tilt = 0.0f;
        g_theContext->condition = 0;
    }
    return g_theContext;
}

/* EFT.MovementContext::SetTilt(System.Single), instance and compiled.
 *
 * No null check, for the reason `mock_native_hurt` gives: a conditional branch
 * inside the first fourteen bytes is a relative branch the detour engine
 * correctly refuses to relocate, and a stand-in for a real method has to have
 * a real prologue. */
static int32_t g_tiltSets = 0;
static void mock_native_set_tilt(void* thisPtr, float tilt, void* methodInfo) {
    (void)methodInfo;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    /* Same reason as `mock_native_apply_condition`: long enough to hold a
     * fourteen-byte jump. */
    g_tiltSets++;
    c->tilt = tilt * 2.0f;
}
MOCK_EXPORT int32_t mock_tilt_sets(void) { return g_tiltSets; }

/* EFT.MovementContext::ApplyCondition(EFT.EPhysicalCondition), instance and
 * compiled. The enum arrives in EDX as a plain integer -- there is no object
 * anywhere in this call -- which is what makes it the regression test. */
static int32_t g_conditionApplies = 0;
static void mock_native_apply_condition(void* thisPtr, int32_t condition,
                                        void* methodInfo) {
    (void)methodInfo;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    /* Three stores rather than one, for the reason `mock_native_tick` gives:
     * `c->condition += condition` compiles to eleven bytes, three short of the
     * jump, so hooking it was refused with "the function is shorter than the
     * jump" -- and the refusal was right. A method that cannot be patched
     * cannot stand in for one that can, and the enum-argument regression this
     * exists for is a *patch* test. */
    g_conditionApplies++;
    c->condition = c->condition + condition;
    c->tilt = c->tilt + 0.0f;
}
MOCK_EXPORT int32_t mock_condition_applies(void) { return g_conditionApplies; }

/* EFT.MovementContext::get_Condition() -> EFT.EPhysicalCondition.
 *
 * An enum **return**, which nothing here had. The host used to classify one as
 * a reference: a mod asking for it got `{"handle":6,"type":"System.Int32"}`,
 * so `asInt()` answered 0 with `ok` true -- a wrong number that reads like a
 * right one -- and a GC handle was taken out that nothing would release. There
 * was no way to notice that from inside this universe until this method
 * existed. */
static void* m_contextGetCondition(void* obj, void** params) {
    (void)params;
    MockMoveContext* c = (MockMoveContext*)obj;
    /* Boxed as an integer, which is what a boxed enum is: the class the
     * runtime reports for it is the enum's, but this mock has one boxed shape
     * and the host reads the payload by the *declared return type*, which is
     * the whole point of the test. */
    return mock_box_i64((int64_t)(c ? c->condition : 0));
}

/* EFT.MovementContext::Aim(System.Single) -> System.Single, **instance** and
 * compiled.
 *
 * The instance half of the postfix proof, and it is a separate method rather
 * than a second patch on `SetTilt` because the engine allows one detour per
 * method. `this` in RCX, the float in XMM1, the `MethodInfo*` in RDX: three
 * slots, so it fits, and its result depends on the context it was called on --
 * which is what makes a postfix that reports the wrong `this`, or a host that
 * read the argument out of the wrong register file, produce a number the test
 * can see. */
static int32_t g_aimCalls = 0;
static float mock_native_aim(void* thisPtr, float amount, void* methodInfo) {
    (void)methodInfo;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    g_aimCalls++;
    return c->tilt + amount;
}
MOCK_EXPORT int32_t mock_aim_calls(void) { return g_aimCalls; }

/* EFT.MovementContext::Ready() -> System.Boolean, **instance** and compiled.
 *
 * The integer half of the typed postfix, which had nothing to stand on. A
 * postfix reports its result out of RAX or XMM0 depending on the declared
 * return type, and the float side has `Aim` -- but every instance method here
 * that returns an integer was **undetourable**: `EFT.Player::get_IsAI` is
 * shorter than the fourteen-byte jump, and `get_Condition`'s prologue holds a
 * relative branch the relocator correctly refuses. So `resultInt` could not be
 * exercised from a mod at all, and a test written against it would have been
 * measuring the refusal.
 *
 * Long enough to patch and it answers from the instance, so a postfix given
 * the wrong `this` produces a value the test can see. */
static int32_t g_readyCalls = 0;
static int32_t mock_native_ready(void* thisPtr, void* methodInfo) {
    (void)methodInfo;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    g_readyCalls++;
    return (c->condition == 0) ? 1 : 0;
}
MOCK_EXPORT int32_t mock_ready_calls(void) { return g_readyCalls; }

/* EFT.MovementContext::Drift(Single, Single), instance and compiled.
 *
 * The typed *prefix* target, and shaped after the real one: `mods/classicmovement`
 * redirects `InertiaSmoothTilt(a, b)` on `this`, which is an instance method
 * taking two floats and returning nothing, suppressed after the handler has
 * read all three. So this is `this` in RCX, a float in XMM1, a float in XMM2 --
 * two arguments in the *floating-point* file at positions 1 and 2, which is the
 * case a frame that counted registers per file rather than per position would
 * get wrong in a way that still produced numbers.
 *
 * The two are combined unevenly -- `a * 10 + b` -- so a handler that read them
 * in the wrong order, or read one twice, leaves a value the test can see. */
static int32_t g_driftCalls = 0;
static void mock_native_drift(void* thisPtr, float a, float b,
                              void* methodInfo) {
    (void)methodInfo;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    /* Long enough to hold a fourteen-byte jump, for the reason every other
     * compiled stand-in here is: a function shorter than the detour is refused,
     * correctly, and would test a refusal rather than a hook. */
    g_driftCalls++;
    c->tilt = a * 10.0f + b;
    c->condition = c->condition + 0;
}
/* Must stay at zero across a suppressing typed prefix. That is the difference
 * between "suppressed the original" and "let it run and then overwrote what it
 * did", and only a side effect can tell them apart. */
MOCK_EXPORT int32_t mock_drift_calls(void) { return g_driftCalls; }
static MockMethod* g_driftMethod = NULL;
typedef void (*FnDrift)(void*, float, float, void*);
static void* m_contextDrift(void* obj, void** params) {
    FnDrift fn = (FnDrift)g_driftMethod->methodPointer;
    fn(obj, *(float*)params[0], *(float*)params[1], NULL);
    return NULL;
}

static MockMethod* g_setTiltMethod = NULL;
static MockMethod* g_applyConditionMethod = NULL;
static MockMethod* g_aimMethod = NULL;
static MockMethod* g_readyMethod = NULL;

typedef void (*FnSetTilt)(void*, float, void*);
typedef void (*FnApplyCondition)(void*, int32_t, void*);

static void* m_contextSetTilt(void* obj, void** params) {
    FnSetTilt fn = (FnSetTilt)g_setTiltMethod->methodPointer;
    fn(obj, *(float*)params[0], NULL);
    return NULL;
}
static void* m_contextApplyCondition(void* obj, void** params) {
    FnApplyCondition fn = (FnApplyCondition)g_applyConditionMethod->methodPointer;
    fn(obj, *(int32_t*)params[0], NULL);
    return NULL;
}
typedef int32_t (*FnReady)(void*, void*);
static void* m_contextReady(void* obj, void** params) {
    (void)params;
    FnReady fn = (FnReady)g_readyMethod->methodPointer;
    return mock_box_bool(fn(obj, NULL));
}
typedef float (*FnAim)(void*, float, void*);
static void* m_contextAim(void* obj, void** params) {
    FnAim fn = (FnAim)g_aimMethod->methodPointer;
    return mock_box_f32(fn(obj, *(float*)params[0], NULL));
}
/* EFT.MovementContext::Step(Single, Int32, String, Single) -> System.Single,
 * instance and compiled.
 *
 * `Quint`'s instance twin, and the pair is the point: the same four leading
 * parameter types, one method static and one not, so the only difference
 * between what a hook is told about them is `this`. It takes register position
 * 0 and pushes every parameter along by one, so `Step`'s fourth declared
 * parameter -- the trailing `System.Single` -- is on the stack while `Quint`'s
 * fourth is in XMM3.
 *
 * That was the silent case. The host reported three arguments here and four
 * there and said nothing about the difference, so a handler reading argument 3
 * got an absence that read exactly like an empty value. This method is what
 * makes that reachable from a test rather than only from a raid. */
static int32_t g_stepCalls = 0;
static float mock_native_step(void* thisPtr, float a, int32_t kind, void* text,
                              float tail, void* methodInfo) {
    (void)methodInfo; (void)text;
    MockMoveContext* c = (MockMoveContext*)thisPtr;
    g_stepCalls++;
    c->tilt = a * 100.0f + (float)kind + tail;
    return c->tilt;
}
MOCK_EXPORT int32_t mock_step_calls(void) { return g_stepCalls; }
static MockMethod* g_stepMethod = NULL;
typedef float (*FnStep)(void*, float, int32_t, void*, float, void*);
static void* m_contextStep(void* obj, void** params) {
    FnStep fn = (FnStep)g_stepMethod->methodPointer;
    return mock_box_f32(fn(obj, *(float*)params[0], *(int32_t*)params[1],
                           params[2], *(float*)params[3], NULL));
}

/* EFT.MovementContext::get_Instance() -> EFT.MovementContext (static) */
static void* m_contextInstance(void* obj, void** params) {
    (void)obj; (void)params;
    return mock_context();
}

static MockMethod g_contextMethods[] = {
    { NULL, "get_Instance", 0, {0,0,0,0}, "EFT.MovementContext",
      m_contextInstance, NULL, 1, NULL },
    { NULL, "SetTilt", 1, {"System.Single",0,0,0}, "System.Void",
      m_contextSetTilt, NULL, 0, (void*)mock_native_set_tilt },
    { NULL, "ApplyCondition", 1, {"EFT.EPhysicalCondition",0,0,0},
      "System.Void", m_contextApplyCondition, NULL, 0,
      (void*)mock_native_apply_condition },
    { NULL, "get_Condition", 0, {0,0,0,0}, "EFT.EPhysicalCondition",
      m_contextGetCondition, NULL, 0, NULL },
    { NULL, "Aim", 1, {"System.Single",0,0,0}, "System.Single",
      m_contextAim, NULL, 0, (void*)mock_native_aim },
    { NULL, "Drift", 2, {"System.Single","System.Single",0,0}, "System.Void",
      m_contextDrift, NULL, 0, (void*)mock_native_drift },
    { NULL, "Ready", 0, {0,0,0,0}, "System.Boolean",
      m_contextReady, NULL, 0, (void*)mock_native_ready },
    { NULL, "Step", 4, {"System.Single","System.Int32","System.String",
                        "System.Single"}, "System.Single",
      m_contextStep, NULL, 0, (void*)mock_native_step },
};

static MockField g_contextFields[] = {
    { "_player", 8,  "EFT.Player"   },
    { "Tilt",    16, "System.Single" },
    { "Condition", 20, "EFT.EPhysicalCondition" },
};

/* A value type, and marked as one -- which is the whole point of it being
 * here. `instanceSize` is the payload rather than the boxed form, matching
 * every other value type in this file; the host subtracts an object header
 * only when the number it is given is larger than one. */
static MockClass g_conditionClass = {
    "EFT", "EPhysicalCondition", &g_objectClass, 4, 1, NULL, 0, NULL, 0
};
static MockClass g_moveContextClass = {
    "EFT", "MovementContext", &g_objectClass, 32, 0,
    g_contextMethods, MOCK_N(g_contextMethods), g_contextFields, MOCK_N(g_contextFields)
};

MOCK_EXPORT float mock_context_tilt(void) { return mock_context()->tilt; }
MOCK_EXPORT int32_t mock_context_condition(void) {
    return mock_context()->condition;
}

/* ------------------------------------------------------------------ *
 * Engine-level knobs  (added for `mods/perf`)
 *
 * A performance mod does not talk to `EFT.*` at all: everything it touches is
 * Unity's own static surface -- `QualitySettings`, `Time`, `Physics`,
 * `Application`, `SystemInfo`. None of that existed here, so the mod's whole
 * resolve-or-refuse path had nothing to resolve *or* refuse against, and a
 * test that only ever sees "absent" proves half of the contract.
 *
 * So this block is deliberately **partial**, and the gaps are the point:
 *
 *   - Some properties are here with both a getter and a setter, which is the
 *     applied case.
 *   - One is here with a getter and **no setter** (`maxQueuedFrames`), which
 *     is the "readable but not writable" refusal.
 *   - Most of `QualitySettings` is simply **absent**, which is the "no such
 *     member on this build" refusal -- the one that matters, because BSG's
 *     IL2CPP build is managed-code-stripped and a setter nothing in the game
 *     calls may genuinely not be there.
 *   - `shadowCascades` **clamps** its input to {0,2,4}, exactly as Unity does,
 *     so the read-back-and-compare path sees a value that is neither the
 *     original nor the requested one. A mod that reported "applied" on the
 *     strength of the setter not erroring would be wrong here and right
 *     everywhere else.
 *   - `anisotropicFiltering` takes an **enum**, which the host's boxed `call`
 *     path cannot build from a JSON scalar. It is here so that refusal is
 *     observed rather than assumed, and so the `bindMethodAs` route past it is
 *     exercised against real metadata.
 *
 * `Time::get_frameCount` and `get_deltaTime` report the mock's own frame
 * thread, so a sampler that divides frames by wall-clock time measures
 * something real: about 120 frames a second, from the loop `mock_frame_loop`
 * has been running since init.
 * ------------------------------------------------------------------ */

static MockClass g_qualityClass;
static MockClass g_timeClass;
static MockClass g_physicsClass;
static MockClass g_sysInfoClass;
static MockClass g_anisoClass;
static MockClass g_threadPriorityClass;

/* The settings themselves, at Unity's own defaults. */
static float   g_qShadowDistance = 150.0f;
static int32_t g_qShadowCascades = 4;
static float   g_qLodBias        = 2.0f;
static int32_t g_qVSyncCount     = 1;
static int32_t g_qSoftParticles  = 1;
static int32_t g_qAniso          = 2;      /* ForceEnable */
static int32_t g_qTextureLimit   = 0;
static int32_t g_qMaxQueuedFrames = 2;     /* getter only, on purpose */
static float   g_timeFixedDelta  = 0.02f;
static float   g_timeScale       = 1.0f;
static int32_t g_physAutoSync    = 1;
static int32_t g_physSolverIters = 6;

/* How many times anything here was written. The harness reads it to tell "the
 * mod applied nothing" from "the mod applied and then restored". */
MOCK_EXPORT int32_t mock_knob_writes(void) { return g_knobWrites; }
MOCK_EXPORT float   mock_shadow_distance(void) { return g_qShadowDistance; }
MOCK_EXPORT int32_t mock_shadow_cascades(void) { return g_qShadowCascades; }
MOCK_EXPORT int32_t mock_target_fps(void) { return g_appTargetFps; }
MOCK_EXPORT int32_t mock_aniso(void) { return g_qAniso; }

static void* q_get_shadowDistance(void* o, void** p) { (void)o; (void)p;
    return mock_box_f32(g_qShadowDistance); }
static void* q_set_shadowDistance(void* o, void** p) { (void)o;
    g_qShadowDistance = *(float*)p[0]; g_knobWrites++; return NULL; }

/* Unity snaps this to one of {0,2,4}; so does this. */
static void* q_get_shadowCascades(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(g_qShadowCascades); }
static void* q_set_shadowCascades(void* o, void** p) { (void)o;
    int32_t v = *(int32_t*)p[0];
    g_qShadowCascades = (v <= 0) ? 0 : (v <= 2 ? 2 : 4);
    g_knobWrites++; return NULL; }

static void* q_get_lodBias(void* o, void** p) { (void)o; (void)p;
    return mock_box_f32(g_qLodBias); }
static void* q_set_lodBias(void* o, void** p) { (void)o;
    g_qLodBias = *(float*)p[0]; g_knobWrites++; return NULL; }

static void* q_get_vSyncCount(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(g_qVSyncCount); }
static void* q_set_vSyncCount(void* o, void** p) { (void)o;
    g_qVSyncCount = *(int32_t*)p[0]; g_knobWrites++; return NULL; }

static void* q_get_softParticles(void* o, void** p) { (void)o; (void)p;
    return mock_box_bool(g_qSoftParticles); }
static void* q_set_softParticles(void* o, void** p) { (void)o;
    g_qSoftParticles = *(int32_t*)p[0] ? 1 : 0; g_knobWrites++; return NULL; }

static void* q_get_masterTextureLimit(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(g_qTextureLimit); }
static void* q_set_masterTextureLimit(void* o, void** p) { (void)o;
    g_qTextureLimit = *(int32_t*)p[0]; g_knobWrites++; return NULL; }

/* Getter with no setter: readable, and refused for writing. */
static void* q_get_maxQueuedFrames(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(g_qMaxQueuedFrames); }

/* The enum pair. Written with the signature a *compiled* IL2CPP method has,
 * because `bindMethodAs` calls the compiled function directly -- an invoker
 * would receive `(obj, params)` where the trampoline puts
 * `(value, MethodInfo*)` and read the argument out of the wrong register.
 * Static, so the enum is in ECX and the MethodInfo* in RDX. */
static void mock_native_set_aniso(int32_t mode, void* methodInfo) {
    (void)methodInfo;
    g_qAniso = mode;
    g_knobWrites++;
}
static int32_t mock_native_get_aniso(void* methodInfo) {
    (void)methodInfo;
    return g_qAniso;
}
static MockMethod* g_setAnisoMethod = NULL;
static MockMethod* g_getAnisoMethod = NULL;
typedef void    (*FnSetAniso)(int32_t, void*);
typedef int32_t (*FnGetAniso)(void*);
static void* q_set_aniso(void* o, void** p) { (void)o;
    FnSetAniso fn = (FnSetAniso)g_setAnisoMethod->methodPointer;
    fn(*(int32_t*)p[0], NULL); return NULL; }
static void* q_get_aniso(void* o, void** p) { (void)o; (void)p;
    FnGetAniso fn = (FnGetAniso)g_getAnisoMethod->methodPointer;
    return mock_box_i64(fn(NULL)); }

static MockMethod g_qualityMethods[] = {
    { NULL, "get_shadowDistance", 0, {0,0,0,0}, "System.Single",
      q_get_shadowDistance, NULL, 1, NULL },
    { NULL, "set_shadowDistance", 1, {"System.Single",0,0,0}, "System.Void",
      q_set_shadowDistance, NULL, 1, NULL },
    { NULL, "get_shadowCascades", 0, {0,0,0,0}, "System.Int32",
      q_get_shadowCascades, NULL, 1, NULL },
    { NULL, "set_shadowCascades", 1, {"System.Int32",0,0,0}, "System.Void",
      q_set_shadowCascades, NULL, 1, NULL },
    { NULL, "get_lodBias", 0, {0,0,0,0}, "System.Single",
      q_get_lodBias, NULL, 1, NULL },
    { NULL, "set_lodBias", 1, {"System.Single",0,0,0}, "System.Void",
      q_set_lodBias, NULL, 1, NULL },
    { NULL, "get_vSyncCount", 0, {0,0,0,0}, "System.Int32",
      q_get_vSyncCount, NULL, 1, NULL },
    { NULL, "set_vSyncCount", 1, {"System.Int32",0,0,0}, "System.Void",
      q_set_vSyncCount, NULL, 1, NULL },
    { NULL, "get_softParticles", 0, {0,0,0,0}, "System.Boolean",
      q_get_softParticles, NULL, 1, NULL },
    { NULL, "set_softParticles", 1, {"System.Boolean",0,0,0}, "System.Void",
      q_set_softParticles, NULL, 1, NULL },
    { NULL, "get_masterTextureLimit", 0, {0,0,0,0}, "System.Int32",
      q_get_masterTextureLimit, NULL, 1, NULL },
    { NULL, "set_masterTextureLimit", 1, {"System.Int32",0,0,0}, "System.Void",
      q_set_masterTextureLimit, NULL, 1, NULL },
    { NULL, "get_maxQueuedFrames", 0, {0,0,0,0}, "System.Int32",
      q_get_maxQueuedFrames, NULL, 1, NULL },
    { NULL, "get_anisotropicFiltering", 0, {0,0,0,0},
      "UnityEngine.AnisotropicFiltering", q_get_aniso, NULL, 1,
      (void*)mock_native_get_aniso },
    { NULL, "set_anisotropicFiltering", 1,
      {"UnityEngine.AnisotropicFiltering",0,0,0}, "System.Void",
      q_set_aniso, NULL, 1, (void*)mock_native_set_aniso },
};

/* `UnityEngine.Time`. `frameCount` and `deltaTime` come off the frame thread
 * that has been running since `il2cpp_init`, so a sampler that divides frames
 * by wall-clock time gets ~120 fps rather than a constant. */
static void* t_get_frameCount(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64((int64_t)g_frameCount); }
static void* t_get_deltaTime(void* o, void** p) { (void)o; (void)p;
    return mock_box_f32((float)g_frameDelta); }
static void* t_get_fixedDeltaTime(void* o, void** p) { (void)o; (void)p;
    return mock_box_f32(g_timeFixedDelta); }
static void* t_set_fixedDeltaTime(void* o, void** p) { (void)o;
    g_timeFixedDelta = *(float*)p[0]; g_knobWrites++; return NULL; }
static void* t_get_timeScale(void* o, void** p) { (void)o; (void)p;
    return mock_box_f32(g_timeScale); }

/* The compiled forms, for the fast path: the frame sampler binds these with
 * `bindMethod`, and a bound call goes to `methodPointer` directly. */
static int32_t mock_native_frame_count(void* methodInfo) {
    (void)methodInfo;
    return (int32_t)g_frameCount;
}
static float mock_native_delta_time(void* methodInfo) {
    (void)methodInfo;
    return (float)g_frameDelta;
}

static MockMethod g_timeMethods[] = {
    { NULL, "get_frameCount", 0, {0,0,0,0}, "System.Int32",
      t_get_frameCount, NULL, 1, (void*)mock_native_frame_count },
    { NULL, "get_deltaTime", 0, {0,0,0,0}, "System.Single",
      t_get_deltaTime, NULL, 1, (void*)mock_native_delta_time },
    { NULL, "get_fixedDeltaTime", 0, {0,0,0,0}, "System.Single",
      t_get_fixedDeltaTime, NULL, 1, NULL },
    { NULL, "set_fixedDeltaTime", 1, {"System.Single",0,0,0}, "System.Void",
      t_set_fixedDeltaTime, NULL, 1, NULL },
    { NULL, "get_timeScale", 0, {0,0,0,0}, "System.Single",
      t_get_timeScale, NULL, 1, NULL },
};

/* `UnityEngine.Physics`. Read-only here on purpose: `mods/perf` reports these
 * and deliberately does not write them, because changing when transforms are
 * synced or how many solver iterations run changes what a raycast hits. */
static void* p_get_autoSyncTransforms(void* o, void** p) { (void)o; (void)p;
    return mock_box_bool(g_physAutoSync); }
static void* p_get_defaultSolverIterations(void* o, void** p) {
    (void)o; (void)p;
    return mock_box_i64(g_physSolverIters); }

static MockMethod g_physicsMethods[] = {
    { NULL, "get_autoSyncTransforms", 0, {0,0,0,0}, "System.Boolean",
      p_get_autoSyncTransforms, NULL, 1, NULL },
    { NULL, "get_defaultSolverIterations", 0, {0,0,0,0}, "System.Int32",
      p_get_defaultSolverIterations, NULL, 1, NULL },
};

/* `UnityEngine.SystemInfo`, for the header line of a performance report. */
static void* s_get_graphicsDeviceName(void* o, void** p) { (void)o; (void)p;
    return mock_string_from("Mock Adapter 9000"); }
static void* s_get_processorCount(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(8); }
static void* s_get_systemMemorySize(void* o, void** p) { (void)o; (void)p;
    return mock_box_i64(32768); }

static MockMethod g_sysInfoMethods[] = {
    { NULL, "get_graphicsDeviceName", 0, {0,0,0,0}, "System.String",
      s_get_graphicsDeviceName, NULL, 1, NULL },
    { NULL, "get_processorCount", 0, {0,0,0,0}, "System.Int32",
      s_get_processorCount, NULL, 1, NULL },
    { NULL, "get_systemMemorySize", 0, {0,0,0,0}, "System.Int32",
      s_get_systemMemorySize, NULL, 1, NULL },
};

/* Two enums, marked as value types, so `classifyType` refuses them and the
 * boxed path cannot build one from a JSON number -- which is the behaviour
 * `mods/perf` reports as a finding rather than works around silently. */
static MockClass g_anisoClass = {
    "UnityEngine", "AnisotropicFiltering", &g_objectClass, 4, 1,
    NULL, 0, NULL, 0
};
static MockClass g_threadPriorityClass = {
    "UnityEngine", "ThreadPriority", &g_objectClass, 4, 1, NULL, 0, NULL, 0
};

static MockClass g_qualityClass = {
    "UnityEngine", "QualitySettings", &g_objectClass, 16, 0,
    g_qualityMethods, MOCK_N(g_qualityMethods), NULL, 0
};
static MockClass g_timeClass = {
    "UnityEngine", "Time", &g_objectClass, 16, 0, g_timeMethods, MOCK_N(g_timeMethods), NULL, 0
};
static MockClass g_physicsClass = {
    "UnityEngine", "Physics", &g_objectClass, 16, 0,
    g_physicsMethods, MOCK_N(g_physicsMethods), NULL, 0
};
static MockClass g_sysInfoClass = {
    "UnityEngine", "SystemInfo", &g_objectClass, 16, 0,
    g_sysInfoMethods, MOCK_N(g_sysInfoMethods), NULL, 0
};

static MockClass* g_corlibClasses[] = {
    &g_objectClass, &g_stringClass, &g_int32Class,
    &g_singleClass, &g_boolClass, &g_voidClass, &g_doubleClass,
    /* `GetType` declares it, so the host has to be able to name it: a return
       type the universe does not contain is refused, and the refusal would
       land on `alive()` rather than on the missing class. */
    &g_typeClass
};
static MockClass* g_unityClasses[] = {
    &g_appClass, &g_frameClass,
    /* added for `mods/perf` */
    &g_qualityClass, &g_timeClass, &g_physicsClass, &g_sysInfoClass,
    &g_anisoClass, &g_threadPriorityClass,
    /* added for `mods/sain`: the shaped-call path needs a non-register-sized
     * value type to exist before it can be exercised */
    &g_vec3Class
};
static MockClass* g_eftClasses[]   = { &g_playerClass, &g_gameWorldClass,
                                       &g_moveContextClass,
                                       &g_conditionClass };

/* Counted rather than written down, for the reason `MOCK_N` exists: a class
 * added to one of the arrays above without touching the number here is a class
 * the host cannot resolve, which reads as a correct "no such type" refusal. The
 * method tables stopped counting by hand a while ago; these were the last three
 * that had not. */
static MockImage g_corlibImage = { "mscorlib.dll",       g_corlibClasses,
                                   MOCK_N(g_corlibClasses) };
static MockImage g_unityImage  = { "UnityEngine.dll",    g_unityClasses,
                                   MOCK_N(g_unityClasses) };
static MockImage g_eftImage    = { "Assembly-CSharp.dll",g_eftClasses,
                                   MOCK_N(g_eftClasses) };

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
static MockMethod* mock_find(MockClass* k, const char* name) {
    for (int32_t i = 0; i < k->methodCount; i++)
        if (strcmp(k->methods[i].name, name) == 0) return &k->methods[i];
    return NULL;
}

/* Which rows have no compiled body, collected as the tables are wired.
 *
 * Collected rather than asserted, because "no `native`" is perfectly correct
 * for a row that only ever goes through `il2cpp_runtime_invoke` -- most of this
 * file is that. What is wrong is *binding* one, and only the test doing the
 * binding knows which it means. So the mock reports and the test decides. */
#define MOCK_MAX_UNCOMPILED 64
static char    g_uncompiled[MOCK_MAX_UNCOMPILED][96];
static int32_t g_uncompiledCount = 0;

static void mock_note_uncompiled(MockClass* k, MockMethod* m) {
    if (g_uncompiledCount >= MOCK_MAX_UNCOMPILED) return;
    snprintf(g_uncompiled[g_uncompiledCount], sizeof(g_uncompiled[0]) - 1,
              "%s.%s::%s", k->ns, k->name, m->name);
    g_uncompiled[g_uncompiledCount][sizeof(g_uncompiled[0]) - 1] = 0;
    g_uncompiledCount++;
}

/* How many rows in the whole universe are invoker-only. */
MOCK_EXPORT int32_t mock_uncompiled_count(void) { return g_uncompiledCount; }

/* The `Namespace.Type::Method` of one of them. */
MOCK_EXPORT const char* mock_uncompiled_name(int32_t i) {
    if (i < 0 || i >= g_uncompiledCount) return NULL;
    return g_uncompiled[i];
}

/* 1 when this method has a compiled body, 0 when it is invoker-only, -1 when
 * there is no such method.
 *
 * The direct question, for a test that is about to bind, detour or time one:
 * -1 and 0 both mean "do not report a number", and they mean different things
 * to whoever reads the failure. */
/* The address the host would detour for this method -- `methodPointer`, which
 * `mock_wire` set to the compiled body where there is one.
 *
 * Exported so that a churn test can take a copy of a method's first bytes,
 * install and remove a detour a thousand times, and compare. "The trampoline
 * put the original back" is otherwise only observable by the method still
 * behaving, which a method that was never called cannot demonstrate. */
MOCK_EXPORT void* mock_method_pointer(const char* nsType, const char* method) {
    int a, c, m;
    if (!nsType || !method) return NULL;
    for (a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (c = 0; c < img->classCount; c++) {
            MockClass* k = img->classes[c];
            char full[96];
            snprintf(full, sizeof(full) - 1, "%s.%s", k->ns, k->name);
            full[sizeof(full) - 1] = 0;
            if (strcmp(full, nsType) != 0) continue;
            for (m = 0; m < k->methodCount; m++) {
                if (strcmp(k->methods[m].name, method) == 0)
                    return k->methods[m].methodPointer;
            }
        }
    }
    return NULL;
}

MOCK_EXPORT int32_t mock_is_compiled(const char* nsType, const char* method) {
    int a, c, m;
    if (!nsType || !method) return -1;
    for (a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (c = 0; c < img->classCount; c++) {
            MockClass* k = img->classes[c];
            char full[96];
            snprintf(full, sizeof(full) - 1, "%s.%s", k->ns, k->name);
            full[sizeof(full) - 1] = 0;
            if (strcmp(full, nsType) != 0) continue;
            for (m = 0; m < k->methodCount; m++) {
                if (strcmp(k->methods[m].name, method) == 0) {
                    return k->methods[m].native != NULL ? 1 : 0;
                }
            }
        }
    }
    return -1;
}

static void mock_wire(void) {
    for (int a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (int c = 0; c < img->classCount; c++) {
            MockClass* k = img->classes[c];
            for (int f = 0; f < k->fieldCount; f++)
                k->fields[f].klass = k;
            for (int m = 0; m < k->methodCount; m++) {
                k->methods[m].klass = k;
                /* The compiled function when the method has one, the invoker
                 * otherwise. Detouring an invoker would see an argument array
                 * where the arguments should be, which is exactly the thing the
                 * argument-decoding tests need to be able to distinguish. */
                k->methods[m].methodPointer = k->methods[m].native
                    ? k->methods[m].native
                    : (void*)k->methods[m].impl;
                if (!k->methods[m].native) {
                    mock_note_uncompiled(k, &k->methods[m]);
                }
            }
        }
    }
    for (int i = 0; i < 3; i++) g_assemblyPtrs[i] = &g_assemblies[i];

    /* The compiled methods' invokers read `methodPointer` back out of the
     * table at call time rather than closing over the function's address, so
     * that a detour installed after wiring is still seen. Bound here because
     * this is the one place that knows the table is complete. */
    g_hurtMethod = mock_find(&g_playerClass, "Hurt");
    g_boostMethod = mock_find(&g_playerClass, "Boost");
    g_sensMethod = mock_find(&g_playerClass, "Sensitivity");
    g_pingMethod = mock_find(&g_playerClass, "Ping");
    g_swayMethod = mock_find(&g_playerClass, "Sway");
    g_quintMethod = mock_find(&g_playerClass, "Quint");
    g_stepMethod = mock_find(&g_moveContextClass, "Step");
    g_setAnisoMethod = mock_find(&g_qualityClass, "set_anisotropicFiltering");
    g_getAnisoMethod = mock_find(&g_qualityClass, "get_anisotropicFiltering");
}

/* The thread that plays Unity's main thread.
 *
 * Started from `il2cpp_init`, so it exists from the moment the host can see a
 * domain -- the same order the game has, where the player loop is already
 * running by the time anything else is up. It calls the compiled function
 * through the method table rather than directly, so a detour installed
 * afterwards is on the path it takes.
 *
 * It never stops. The process it runs in is a test harness that exits when it
 * is done, and a loop with a shutdown flag would only add a way for the host's
 * hook to be removed while a frame is inside it -- which is a real hazard in
 * the game and not one this mock is trying to model.
 */
static DWORD g_frameThreadId = 0;

/* Stops the frame loop calling the per-frame method without stopping the
 * thread. The host's drain hook is on that method, so this is the only way a
 * test outside the game can reproduce what happens when the method a drain
 * bound to goes quiet -- which is what a hook bound to `EFT.GameWorld::Update`
 * does the moment a raid ends. Default is running; nothing in the existing
 * gate touches it. */
static volatile LONG g_framePaused = 0;
MOCK_EXPORT void mock_frame_pause(int32_t on) {
    InterlockedExchange(&g_framePaused, on ? 1 : 0);
}

static DWORD WINAPI mock_frame_loop(LPVOID arg) {
    (void)arg;
    for (;;) {
        if (!g_framePaused && g_frameMethod && g_frameMethod->methodPointer) {
            FnFrame fn = (FnFrame)g_frameMethod->methodPointer;
            fn(NULL);
        }
        Sleep(8);   /* about 120 frames a second */
    }
}

static void mock_frame_start(void) {
    if (g_frameThreadId != 0) return;
    g_frameMethod = mock_find(&g_frameClass, "PerformUpdate");
    /* Bound here for the same reason: an invoker reads `methodPointer` back
     * out of the table at call time so that a detour installed later is on the
     * path it takes, and this is the first point where the table is complete. */
    g_setTiltMethod = mock_find(&g_moveContextClass, "SetTilt");
    g_applyConditionMethod = mock_find(&g_moveContextClass, "ApplyCondition");
    g_aimMethod = mock_find(&g_moveContextClass, "Aim");
    g_readyMethod = mock_find(&g_moveContextClass, "Ready");
    g_driftMethod = mock_find(&g_moveContextClass, "Drift");
    HANDLE h = CreateThread(NULL, 0, mock_frame_loop, NULL, 0, &g_frameThreadId);
    if (h) CloseHandle(h);
}

/* The thread the frame loop runs on, and how many frames it has run. The
 * harness reads the first one and compares it with the thread the host says a
 * queued callback ran on: equal is the whole assertion. */
MOCK_EXPORT uint32_t mock_frame_thread_id(void) {
    return (uint32_t)g_frameThreadId;
}
MOCK_EXPORT int32_t mock_frame_count(void) { return (int32_t)g_frameCount; }

/* `il2cpp_class_from_type`, which this mock needs for a reason worth writing
 * down: without it the host cannot tell a value type from a reference, and its
 * fallback -- "anything I do not recognise by name is an object" -- turns an
 * enum argument into a GC handle over the integer 2.
 *
 * Types here are their own name strings (see `il2cpp_method_get_param`), so
 * this is a lookup by name across the universe. A class pointer is accepted
 * too, because `il2cpp_class_get_type` returns the class itself, and a caller
 * that round-trips one through here should get it back rather than have its
 * bytes read as text.
 */
MOCK_EXPORT void* il2cpp_class_from_type(void* type) {
    if (!type) return NULL;
    for (int a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (int c = 0; c < img->classCount; c++)
            if ((void*)img->classes[c] == type) return type;
    }
    const char* want = (const char*)type;
    for (int a = 0; a < 3; a++) {
        MockImage* img = g_assemblies[a].image;
        for (int c = 0; c < img->classCount; c++) {
            MockClass* k = img->classes[c];
            char full[256];
            if (k->ns && k->ns[0]) {
                size_t nsn = strlen(k->ns);
                size_t nn = strlen(k->name);
                if (nsn + nn + 2 > sizeof(full)) continue;
                memcpy(full, k->ns, nsn);
                full[nsn] = '.';
                memcpy(full + nsn + 1, k->name, nn + 1);
            } else {
                size_t nn = strlen(k->name);
                if (nn + 1 > sizeof(full)) continue;
                memcpy(full, k->name, nn + 1);
            }
            if (strcmp(full, want) == 0) return k;
        }
    }
    return NULL;
}

/* The name the game actually exports.
 *
 * The host looks up `il2cpp_class_from_il2cpp_type`, which is what
 * `GameAssembly.dll` exports; `il2cpp_class_from_type` above is this mock's
 * own spelling and nothing outside this file asked for it. So every host path
 * that classifies a declared type -- enum arguments, value-type fields, the
 * struct-return shape -- silently got "the runtime could not name a class for
 * it" here, and the tests written to prove those paths passed because the
 * refusal was the same shape as a pass. A mock that answers a name the real
 * runtime does not export is not a stand-in for it. */
MOCK_EXPORT void* il2cpp_class_from_il2cpp_type(void* type) {
    return il2cpp_class_from_type(type);
}

/* ------------------------------------------------------------------ *
 * The IL2CPP C API
 * ------------------------------------------------------------------ */

MOCK_EXPORT void il2cpp_set_data_dir(const char* dir) { (void)dir; }
MOCK_EXPORT void il2cpp_set_config_dir(const char* dir) { (void)dir; }

MOCK_EXPORT void* il2cpp_init(const char* name) {
    (void)name;
    mock_wire();
    /* The player loop, such as it is. After `mock_wire`, because it calls the
     * method through `methodPointer` and that is where it gets filled in. */
    mock_frame_start();
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

/* Walks the base chain, as the real one does.
 *
 * It used to look at the named class only, which made every inherited method
 * unreachable -- including `System.Object::GetType`, which is what `alive()`
 * is. A mod asking a live `EFT.MovementContext` whether it exists got "no such
 * method", which the host reports as a failed call and `alive()` reports as
 * **false**: the mock's shape became a statement about the object. */
MOCK_EXPORT void* il2cpp_class_get_method_from_name(void* c, const char* name, int argc) {
    MockClass* k = (MockClass*)c;
    while (k) {
        for (int32_t i = 0; i < k->methodCount; i++) {
            if (strcmp(k->methods[i].name, name) != 0) continue;
            if (argc >= 0 && (uint32_t)argc != k->methods[i].paramCount) continue;
            return &k->methods[i];
        }
        k = k->parent;
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
/* Field attributes. 0x0010 is FIELD_ATTRIBUTE_STATIC; nothing else is modelled.
 *
 * This was missing entirely, and its absence is exactly the failure shape this
 * file exists to prevent: `il2cpp.nim`'s `fieldFlags` answers 0 for a runtime
 * that does not export it, so `fieldIsStatic` answered *false for every field
 * in the universe* -- and a check that "the static field was refused" would
 * have passed against a binding that never asked, because a static field it
 * cannot recognise looks like an instance field with a plausible offset. */
MOCK_EXPORT uint32_t il2cpp_field_get_flags(void* f) {
    if (!f) return 0;
    return ((MockField*)f)->isStatic ? 0x0010u : 0u;
}
/* The class's static storage. Counted, because the only way to tell a static
 * read from an instance read of the same offset is whether this was called. */
MOCK_EXPORT void* il2cpp_class_get_static_field_data(void* c) {
    ++g_staticDataCalls;
    return c ? ((MockClass*)c)->staticData : NULL;
}
/* How wide a field is, from its declared type.
 *
 * This copied four bytes for every field, which is right for an `int` or a
 * `float` and wrong for every reference: a pointer read four bytes at a time is
 * a truncated pointer, and the caller then dereferences the low half of an
 * address. A mock that cannot represent a reference field cannot test one. */
static int32_t mock_field_width(const char* typeName) {
    if (!typeName) return 4;
    if (strcmp(typeName, "System.Int64") == 0 ||
        strcmp(typeName, "System.UInt64") == 0 ||
        strcmp(typeName, "System.Double") == 0 ||
        strcmp(typeName, "System.IntPtr") == 0) return 8;
    if (strcmp(typeName, "System.Boolean") == 0 ||
        strcmp(typeName, "System.Byte") == 0 ||
        strcmp(typeName, "System.SByte") == 0) return 1;
    if (strcmp(typeName, "System.Int16") == 0 ||
        strcmp(typeName, "System.UInt16") == 0 ||
        strcmp(typeName, "System.Char") == 0) return 2;
    if (strcmp(typeName, "System.Int32") == 0 ||
        strcmp(typeName, "System.UInt32") == 0 ||
        strcmp(typeName, "System.Single") == 0) return 4;
    /* Anything else is a reference: a pointer. */
    return 8;
}

MOCK_EXPORT void il2cpp_field_get_value(void* o, void* f, void* out) {
    if (!o || !f || !out) return;
    MockField* fl = (MockField*)f;
    memcpy(out, (char*)o + fl->offset, (size_t)mock_field_width(fl->typeName));
}
MOCK_EXPORT void il2cpp_field_set_value(void* o, void* f, void* v) {
    if (!o || !f || !v) return;
    MockField* fl = (MockField*)f;
    memcpy((char*)o + fl->offset, v, (size_t)mock_field_width(fl->typeName));
}
/* The boxed path to a static field, which was a pair of no-ops.
 *
 * A no-op leaves the caller's cell holding whatever it held -- a fresh cell is
 * zeroed, so every static field read back as 0 and every write was discarded,
 * both silently. That is the second mechanism the fast path's static binding
 * is checked against: two readers of the same storage, agreeing, is what makes
 * an offset right rather than lucky, and a no-op agrees with nothing. */
MOCK_EXPORT void il2cpp_field_static_get_value(void* f, void* out) {
    MockField* fl = (MockField*)f;
    if (!fl || !out || !fl->isStatic || !fl->klass || !fl->klass->staticData)
        return;
    memcpy(out, (char*)fl->klass->staticData + fl->offset,
           (size_t)mock_field_width(fl->typeName));
}
MOCK_EXPORT void il2cpp_field_static_set_value(void* f, void* v) {
    MockField* fl = (MockField*)f;
    if (!fl || !v || !fl->isStatic || !fl->klass || !fl->klass->staticData)
        return;
    memcpy((char*)fl->klass->staticData + fl->offset, v,
           (size_t)mock_field_width(fl->typeName));
}

MOCK_EXPORT const char* il2cpp_property_get_name(void* p) { (void)p; return ""; }
MOCK_EXPORT void* il2cpp_property_get_get_method(void* p) { (void)p; return NULL; }
MOCK_EXPORT void* il2cpp_property_get_set_method(void* p) { (void)p; return NULL; }

/* Real IL2CPP invokes in two steps: `runtime_invoke` calls the method's
 * per-signature *invoker*, and the invoker unpacks the boxed argument array
 * and calls `methodPointer` -- the compiled function -- indirectly.
 *
 * This used to call `methodPointer` itself, which was right while
 * `methodPointer` was the invoker and catastrophic once methods grew a
 * `native`: it handed `(obj, params)` to a function whose real signature is
 * `(float, MethodInfo*)`, so the returned float came back as a `void*` and the
 * caller unboxed it by dereferencing it. That is the segfault the suppression
 * test hit, and it was the mock's, not the engine's -- the replaced value
 * never reached a boxing step because there was none in the path.
 *
 * A method with no `native` is one whose `impl` *is* its whole implementation,
 * so it is called directly; there is nothing compiled underneath it. */
MOCK_EXPORT void* il2cpp_runtime_invoke(void* m, void* obj, void** params, void** exc) {
    if (exc) *exc = NULL;
    MockMethod* mm = (MockMethod*)m;
    if (!mm || !mm->impl) return NULL;
    if (!mm->native && !mm->methodPointer) return NULL;
    return mm->impl(obj, params);
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

/* GC handles.
 *
 * This was a 256-entry array that only ever grew, with `il2cpp_gchandle_free`
 * as a no-op -- which is a fair sketch of the API and a bad stand-in for it.
 * Real IL2CPP recycles a freed handle, and a host that frees every handle it
 * takes still ran this table out after two hundred and fifty-six calls: the
 * two hundred and fifty-seventh `resolve` of a live object answered 0, the host
 * correctly reported "the runtime would not give a handle", and the failure was
 * in the mock. Nothing noticed until something churned.
 *
 * So: a free list, and a count of what is live -- which is worth more than the
 * recycling. `mock_gchandle_live` is the *runtime's* view of how many handles
 * the host is holding, and it is the only measurement in this universe that
 * cannot be answered by the host's own bookkeeping. A host whose handle table
 * looks flat while this climbs is a host that lost the GC handle behind a slot
 * it reused. */
#define MAX_HANDLES 4096
static void* g_handles[MAX_HANDLES];
static uint32_t g_handleFree[MAX_HANDLES];
static uint32_t g_handleFreeCount = 0;
static int32_t  g_handleLive = 0;
static uint32_t g_handleCount = 0;

MOCK_EXPORT uint32_t il2cpp_gchandle_new(void* o, int32_t pinned) {
    (void)pinned;
    uint32_t h;
    if (g_handleFreeCount > 0) {
        h = g_handleFree[--g_handleFreeCount];
    } else {
        if (g_handleCount >= MAX_HANDLES) return 0;
        h = ++g_handleCount;
    }
    g_handles[h - 1] = o;
    g_handleLive++;
    return h;
}
MOCK_EXPORT void* il2cpp_gchandle_get_target(uint32_t h) {
    if (h == 0 || h > g_handleCount) return NULL;
    return g_handles[h - 1];
}
MOCK_EXPORT void il2cpp_gchandle_free(uint32_t h) {
    if (h == 0 || h > g_handleCount) return;
    if (g_handles[h - 1] == NULL) return;   /* freeing one twice */
    g_handles[h - 1] = NULL;
    if (g_handleFreeCount < MAX_HANDLES) g_handleFree[g_handleFreeCount++] = h;
    g_handleLive--;
}
/* How many handles the host is holding, from the runtime's side of the fence. */
MOCK_EXPORT int32_t mock_gchandle_live(void) { return g_handleLive; }
MOCK_EXPORT int32_t mock_gchandle_high_water(void) { return (int32_t)g_handleCount; }

/* The collector's write barrier.
 *
 * Exported because `fast.nim`'s `writePtr` now routes a reference store
 * through it, and a stand-in that omits it makes that path unreachable: the
 * binding finds no entry, falls back to the plain store, and a test asserting
 * "the field was written" passes without ever exercising the barrier. That is
 * the failure shape this stand-in exists to prevent, so the counter below is
 * the assertion's actual subject -- `mock_wbarrier_calls()` is how a mod
 * proves the store went through the collector rather than around it. */
static int32_t g_wbarrierCalls = 0;

MOCK_EXPORT void il2cpp_gc_wbarrier_set_field(void* obj, void** field, void* value) {
    (void)obj;
    ++g_wbarrierCalls;
    if (field) *field = value;
}

MOCK_EXPORT int32_t mock_wbarrier_calls(void) { return g_wbarrierCalls; }

MOCK_EXPORT void il2cpp_free(void* p) { free(p); }
