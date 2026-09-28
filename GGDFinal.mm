#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#include <atomic>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>
#include <utility>
#include <stdint.h>

// GGD Identity Overlay v5 - checked runtime-discovery build
// Target reference: com.seayoo.ggd / 1.1.13 / arm64 / iOS 18+
//
// Design goals:
//  1. Constructor does UIKit only; no IL2CPP access at injection time.
//  2. Scan is manual and runs on an attached background thread.
//  3. No hard-coded game/player memory offsets.
//  4. Runtime metadata (FieldInfo/MethodInfo) is used to discover fields/methods.
//  5. List/Dictionary are enumerated through managed methods, not guessed layouts.
//  6. No Camera/Transform/world-to-screen access in this stage.
//
// This stage is intentionally diagnostic-first: it should establish a stable
// path to GooseGame -> players -> player objects -> name/faction/career.
// Role-name localization is added only after real runtime IDs are observed.

struct Il2CppDomain;
struct Il2CppThread;
struct Il2CppAssembly;
struct Il2CppImage;
struct Il2CppClass;
struct FieldInfo;
struct MethodInfo;
struct Il2CppType;
struct Il2CppObject;
struct Il2CppString;
struct Il2CppException;

using t_domain_get = Il2CppDomain* (*)();
using t_thread_attach = Il2CppThread* (*)(Il2CppDomain*);
using t_domain_get_assemblies = const Il2CppAssembly** (*)(Il2CppDomain*, size_t*);
using t_assembly_get_image = const Il2CppImage* (*)(const Il2CppAssembly*);
using t_image_get_name = const char* (*)(const Il2CppImage*);
using t_class_from_name = Il2CppClass* (*)(const Il2CppImage*, const char*, const char*);
using t_class_get_name = const char* (*)(Il2CppClass*);
using t_class_get_namespace = const char* (*)(Il2CppClass*);
using t_class_get_parent = Il2CppClass* (*)(Il2CppClass*);
using t_class_is_enum = bool (*)(Il2CppClass*);
using t_class_enum_basetype = const Il2CppType* (*)(Il2CppClass*);
using t_class_get_fields = FieldInfo* (*)(Il2CppClass*, void**);
using t_class_get_field = FieldInfo* (*)(Il2CppClass*, const char*);
using t_class_get_method = const MethodInfo* (*)(Il2CppClass*, const char*, int);
using t_field_get_name = const char* (*)(FieldInfo*);
using t_field_get_flags = uint32_t (*)(FieldInfo*);
using t_field_get_type = const Il2CppType* (*)(FieldInfo*);
using t_field_get_value = void (*)(Il2CppObject*, FieldInfo*, void*);
using t_field_get_value_object = Il2CppObject* (*)(FieldInfo*, Il2CppObject*);
using t_field_static_get_value = void (*)(FieldInfo*, void*);
using t_type_get_name = const char* (*)(const Il2CppType*);
using t_type_get_type = int32_t (*)(const Il2CppType*);
using t_object_get_class = Il2CppClass* (*)(Il2CppObject*);
using t_object_unbox = void* (*)(Il2CppObject*);
using t_runtime_invoke = Il2CppObject* (*)(const MethodInfo*, void*, void**, Il2CppException**);
using t_string_length = int32_t (*)(Il2CppString*);
using t_string_chars = const uint16_t* (*)(Il2CppString*);

static void *resolveSymbol(void *handle, const char *name) {
    void *p = handle ? dlsym(handle, name) : nullptr;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

template <typename T>
static bool resolveInto(T &slot, void *handle, const char *name) {
    void *p = resolveSymbol(handle, name);
    if (!p) return false;
    slot = reinterpret_cast<T>(p);
    return true;
}

static void *findUnityHandle() {
    const uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        if (strstr(path, "UnityFramework.framework/UnityFramework") || strstr(path, "/UnityFramework")) {
            void *h = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
            if (h) return h;
        }
    }
    return nullptr;
}

struct GGDIl2CppAPI {
    t_domain_get domain_get = nullptr;
    t_thread_attach thread_attach = nullptr;
    t_domain_get_assemblies domain_get_assemblies = nullptr;
    t_assembly_get_image assembly_get_image = nullptr;
    t_image_get_name image_get_name = nullptr;
    t_class_from_name class_from_name = nullptr;
    t_class_get_name class_get_name = nullptr;
    t_class_get_namespace class_get_namespace = nullptr;
    t_class_get_parent class_get_parent = nullptr;
    t_class_is_enum class_is_enum = nullptr;
    t_class_enum_basetype class_enum_basetype = nullptr;
    t_class_get_fields class_get_fields = nullptr;
    t_class_get_field class_get_field = nullptr;
    t_class_get_method class_get_method = nullptr;
    t_field_get_name field_get_name = nullptr;
    t_field_get_flags field_get_flags = nullptr;
    t_field_get_type field_get_type = nullptr;
    t_field_get_value field_get_value = nullptr;
    t_field_get_value_object field_get_value_object = nullptr;
    t_field_static_get_value field_static_get_value = nullptr;
    t_type_get_name type_get_name = nullptr;
    t_type_get_type type_get_type = nullptr;
    t_object_get_class object_get_class = nullptr;
    t_object_unbox object_unbox = nullptr;
    t_runtime_invoke runtime_invoke = nullptr;
    t_string_length string_length = nullptr;
    t_string_chars string_chars = nullptr;
    void *unityHandle = nullptr;

    bool resolveAll(std::string &missing) {
        unityHandle = findUnityHandle();
        if (!unityHandle) { missing = "UnityFramework 未加载"; return false; }
        struct Req { bool ok; const char *name; };
        std::vector<Req> req;
        req.push_back({resolveInto(domain_get, unityHandle, "il2cpp_domain_get"), "domain_get"});
        req.push_back({resolveInto(thread_attach, unityHandle, "il2cpp_thread_attach"), "thread_attach"});
        req.push_back({resolveInto(domain_get_assemblies, unityHandle, "il2cpp_domain_get_assemblies"), "domain_get_assemblies"});
        req.push_back({resolveInto(assembly_get_image, unityHandle, "il2cpp_assembly_get_image"), "assembly_get_image"});
        req.push_back({resolveInto(image_get_name, unityHandle, "il2cpp_image_get_name"), "image_get_name"});
        req.push_back({resolveInto(class_from_name, unityHandle, "il2cpp_class_from_name"), "class_from_name"});
        req.push_back({resolveInto(class_get_name, unityHandle, "il2cpp_class_get_name"), "class_get_name"});
        req.push_back({resolveInto(class_get_namespace, unityHandle, "il2cpp_class_get_namespace"), "class_get_namespace"});
        req.push_back({resolveInto(class_get_parent, unityHandle, "il2cpp_class_get_parent"), "class_get_parent"});
        req.push_back({resolveInto(class_is_enum, unityHandle, "il2cpp_class_is_enum"), "class_is_enum"});
        req.push_back({resolveInto(class_enum_basetype, unityHandle, "il2cpp_class_enum_basetype"), "class_enum_basetype"});
        req.push_back({resolveInto(class_get_fields, unityHandle, "il2cpp_class_get_fields"), "class_get_fields"});
        req.push_back({resolveInto(class_get_field, unityHandle, "il2cpp_class_get_field_from_name"), "class_get_field_from_name"});
        req.push_back({resolveInto(class_get_method, unityHandle, "il2cpp_class_get_method_from_name"), "class_get_method_from_name"});
        req.push_back({resolveInto(field_get_name, unityHandle, "il2cpp_field_get_name"), "field_get_name"});
        req.push_back({resolveInto(field_get_flags, unityHandle, "il2cpp_field_get_flags"), "field_get_flags"});
        req.push_back({resolveInto(field_get_type, unityHandle, "il2cpp_field_get_type"), "field_get_type"});
        req.push_back({resolveInto(field_get_value, unityHandle, "il2cpp_field_get_value"), "field_get_value"});
        req.push_back({resolveInto(field_get_value_object, unityHandle, "il2cpp_field_get_value_object"), "field_get_value_object"});
        req.push_back({resolveInto(field_static_get_value, unityHandle, "il2cpp_field_static_get_value"), "field_static_get_value"});
        req.push_back({resolveInto(type_get_name, unityHandle, "il2cpp_type_get_name"), "type_get_name"});
        req.push_back({resolveInto(type_get_type, unityHandle, "il2cpp_type_get_type"), "type_get_type"});
        req.push_back({resolveInto(object_get_class, unityHandle, "il2cpp_object_get_class"), "object_get_class"});
        req.push_back({resolveInto(object_unbox, unityHandle, "il2cpp_object_unbox"), "object_unbox"});
        req.push_back({resolveInto(runtime_invoke, unityHandle, "il2cpp_runtime_invoke"), "runtime_invoke"});
        req.push_back({resolveInto(string_length, unityHandle, "il2cpp_string_length"), "string_length"});
        req.push_back({resolveInto(string_chars, unityHandle, "il2cpp_string_chars"), "string_chars"});

        missing.clear();
        for (const auto &r : req) if (!r.ok) {
            if (!missing.empty()) missing += ",";
            missing += r.name;
        }
        return missing.empty();
    }

    bool attach() const {
        if (!domain_get || !thread_attach) return false;
        Il2CppDomain *d = domain_get();
        if (!d) return false;
        return thread_attach(d) != nullptr;
    }

    Il2CppClass *findClass(const char *ns, const char *name) const {
        if (!ns || !name || !domain_get || !domain_get_assemblies || !assembly_get_image || !class_from_name) return nullptr;
        Il2CppDomain *d = domain_get();
        if (!d) return nullptr;
        size_t count = 0;
        const Il2CppAssembly **assemblies = domain_get_assemblies(d, &count);
        if (!assemblies || count == 0 || count > 4096) return nullptr;
        for (size_t i = 0; i < count; ++i) {
            if (!assemblies[i]) continue;
            const Il2CppImage *img = assembly_get_image(assemblies[i]);
            if (!img) continue;
            Il2CppClass *c = class_from_name(img, ns, name);
            if (c) return c;
        }
        return nullptr;
    }

    Il2CppClass *findAnyClass(const std::vector<std::pair<std::string,std::string>> &candidates) const {
        for (const auto &c : candidates) {
            if (Il2CppClass *k = findClass(c.first.c_str(), c.second.c_str())) return k;
        }
        return nullptr;
    }

    std::string classLabel(Il2CppClass *klass) const {
        if (!klass || !class_get_name) return "?";
        const char *name = class_get_name(klass);
        const char *ns = class_get_namespace ? class_get_namespace(klass) : nullptr;
        if (ns && *ns && name && *name) return std::string(ns) + "." + name;
        return name ? std::string(name) : "?";
    }

    FieldInfo *findField(Il2CppClass *klass, const char *name) const {
        if (!klass || !name || !class_get_field) return nullptr;
        return class_get_field(klass, name);
    }

    const MethodInfo *findMethod(Il2CppClass *klass, const char *name, int argc) const {
        if (!klass || !name || !class_get_method) return nullptr;
        return class_get_method(klass, name, argc);
    }
};

static GGDIl2CppAPI g_api;
static std::mutex g_apiMutex;

static bool safeManagedString(Il2CppString *s, NSString **out) {
    if (out) *out = nil;
    if (!s || !g_api.string_length || !g_api.string_chars) return false;
    const int32_t len = g_api.string_length(s);
    if (len <= 0 || len > 128) return false;
    const uint16_t *chars = g_api.string_chars(s);
    if (!chars) return false;
    NSString *value = [[NSString alloc] initWithCharacters:(const unichar *)chars length:(NSUInteger)len];
    if (out) *out = value;
    return value.length > 0;
}

static bool fieldObject(Il2CppObject *object, FieldInfo *field, Il2CppObject **out) {
    if (out) *out = nullptr;
    if (!object || !field || !g_api.field_get_value) return false;
    Il2CppObject *value = nullptr;
    g_api.field_get_value(object, field, &value);
    if (out) *out = value;
    return true;
}

static bool fieldStaticObject(FieldInfo *field, Il2CppObject **out) {
    if (out) *out = nullptr;
    if (!field || !g_api.field_static_get_value) return false;
    Il2CppObject *value = nullptr;
    g_api.field_static_get_value(field, &value);
    if (out) *out = value;
    return true;
}

static Il2CppObject *fieldValueObject(Il2CppObject *object, FieldInfo *field) {
    if (!object || !field || !g_api.field_get_value_object) return nullptr;
    return g_api.field_get_value_object(field, object);
}

static NSString *fieldString(Il2CppObject *object, FieldInfo *field) {
    Il2CppObject *raw = fieldValueObject(object, field);
    if (!raw) return nil;
    NSString *value = nil;
    if (!safeManagedString((Il2CppString *)raw, &value)) return nil;
    return value;
}

static bool boxedI32(Il2CppObject *boxed, int32_t *out) {
    if (out) *out = 0;
    if (!boxed || !g_api.object_get_class || !g_api.object_unbox || !g_api.class_get_name) return false;
    Il2CppClass *k = g_api.object_get_class(boxed);
    if (!k) return false;
    const char *n = g_api.class_get_name(k);
    if (!n) return false;

    bool fourByte = (strcmp(n, "Int32") == 0 || strcmp(n, "System.Int32") == 0 ||
                     strcmp(n, "UInt32") == 0 || strcmp(n, "System.UInt32") == 0);
    if (g_api.class_is_enum && g_api.class_enum_basetype && g_api.type_get_type && g_api.class_is_enum(k)) {
        const Il2CppType *base = g_api.class_enum_basetype(k);
        const int32_t code = base ? g_api.type_get_type(base) : -1;
        // IL2CPP_TYPE_I4 = 8, IL2CPP_TYPE_U4 = 9.
        fourByte = (code == 8 || code == 9);
    }
    if (!fourByte) return false;

    void *p = g_api.object_unbox(boxed);
    if (!p) return false;
    int32_t value = *(int32_t *)p;
    if (out) *out = value;
    return true;
}

static bool fieldI32(Il2CppObject *object, FieldInfo *field, int32_t *out) {
    if (out) *out = 0;
    return boxedI32(fieldValueObject(object, field), out);
}

static std::string typeName(FieldInfo *field) {
    if (!field || !g_api.field_get_type || !g_api.type_get_name) return "?";
    const Il2CppType *t = g_api.field_get_type(field);
    const char *n = t ? g_api.type_get_name(t) : nullptr;
    return n ? std::string(n) : "?";
}

static std::string fieldName(FieldInfo *field) {
    const char *n = (field && g_api.field_get_name) ? g_api.field_get_name(field) : nullptr;
    return n ? std::string(n) : "?";
}

static bool isStaticField(FieldInfo *field) {
    if (!field || !g_api.field_get_flags) return false;
    return (g_api.field_get_flags(field) & 0x0010u) != 0u;
}

static std::vector<FieldInfo *> enumerateFields(Il2CppClass *klass) {
    std::vector<FieldInfo *> result;
    if (!klass || !g_api.class_get_fields) return result;
    for (Il2CppClass *c = klass; c; c = g_api.class_get_parent ? g_api.class_get_parent(c) : nullptr) {
        void *iter = nullptr;
        for (int guard = 0; guard < 512; ++guard) {
            FieldInfo *f = g_api.class_get_fields(c, &iter);
            if (!f) break;
            result.push_back(f);
        }
    }
    return result;
}

static Il2CppObject *invokeObject(const MethodInfo *method, Il2CppObject *instance, std::vector<void *> params, bool *okOut) {
    if (okOut) *okOut = false;
    if (!method || !g_api.runtime_invoke) return nullptr;
    Il2CppException *exception = nullptr;
    void **paramPtr = params.empty() ? nullptr : params.data();
    Il2CppObject *ret = g_api.runtime_invoke(method, instance, paramPtr, &exception);
    if (exception) return nullptr;
    if (okOut) *okOut = true;
    return ret;
}

static bool invokeInt32(const MethodInfo *method, Il2CppObject *instance, int32_t *out) {
    if (out) *out = 0;
    bool ok = false;
    Il2CppObject *boxed = invokeObject(method, instance, {}, &ok);
    if (!ok || !boxed || !g_api.object_unbox) return false;
    void *p = g_api.object_unbox(boxed);
    if (!p) return false;
    if (out) *out = *(int32_t *)p;
    return true;
}

static bool invokeBool(const MethodInfo *method, Il2CppObject *instance, bool *out) {
    if (out) *out = false;
    bool ok = false;
    Il2CppObject *boxed = invokeObject(method, instance, {}, &ok);
    if (!ok || !boxed || !g_api.object_unbox) return false;
    void *p = g_api.object_unbox(boxed);
    if (!p) return false;
    if (out) *out = (*(uint8_t *)p) != 0;
    return true;
}

static bool invokeNoArgObject(const MethodInfo *method, Il2CppObject *instance, Il2CppObject **out) {
    if (out) *out = nullptr;
    bool ok = false;
    Il2CppObject *ret = invokeObject(method, instance, {}, &ok);
    if (out) *out = ret;
    return ok && ret != nullptr;
}

static Il2CppObject *listItem(Il2CppObject *list, int32_t index) {
    if (!list || !g_api.object_get_class) return nullptr;
    Il2CppClass *klass = g_api.object_get_class(list);
    if (!klass) return nullptr;
    const MethodInfo *item = g_api.class_get_method ? g_api.class_get_method(klass, "get_Item", 1) : nullptr;
    if (!item) return nullptr;
    int32_t arg = index;
    std::vector<void *> params = { &arg };
    bool ok = false;
    return invokeObject(item, list, params, &ok);
}

static bool listCount(Il2CppObject *list, int32_t *outCount) {
    if (outCount) *outCount = 0;
    if (!list || !g_api.object_get_class) return false;
    Il2CppClass *klass = g_api.object_get_class(list);
    if (!klass) return false;
    const MethodInfo *count = g_api.class_get_method ? g_api.class_get_method(klass, "get_Count", 0) : nullptr;
    if (!count) return false;
    return invokeInt32(count, list, outCount);
}

static bool looksLikeList(Il2CppObject *object) {
    if (!object || !g_api.object_get_class) return false;
    Il2CppClass *k = g_api.object_get_class(object);
    std::string n = g_api.classLabel(k);
    return n.find("System.Collections.Generic.List") != std::string::npos || n.find("List<") != std::string::npos;
}

static bool looksLikeDictionary(Il2CppObject *object) {
    if (!object || !g_api.object_get_class) return false;
    Il2CppClass *k = g_api.object_get_class(object);
    std::string n = g_api.classLabel(k);
    return n.find("System.Collections.Generic.Dictionary") != std::string::npos || n.find("Dictionary<") != std::string::npos;
}

static Il2CppObject *findStaticGameInstance(std::string &how) {
    how.clear();
    Il2CppClass *tutorial = g_api.findClass("Goose.Guidance", "Tutorial");
    if (tutorial) {
        FieldInfo *gameField = g_api.findField(tutorial, "<Game>k__BackingField");
        if (gameField) {
            Il2CppObject *game = nullptr;
            if (fieldStaticObject(gameField, &game) && game) {
                how = "Tutorial.<Game>k__BackingField";
                return game;
            }
        }
    }

    Il2CppClass *app = g_api.findClass("Adam.Gameplay", "App");
    if (app) {
        FieldInfo *gameField = g_api.findField(app, "game");
        if (gameField) {
            Il2CppObject *game = nullptr;
            if (fieldStaticObject(gameField, &game) && game) {
                how = "Adam.Gameplay.App.game";
                return game;
            }
        }
    }

    return nullptr;
}

static Il2CppObject *findGooseGame(Il2CppObject *gameSystems, std::string &how) {
    how.clear();
    if (!gameSystems || !g_api.object_get_class) return nullptr;

    Il2CppClass *gooseClass = g_api.findClass("Goose", "GooseGame");
    if (!gooseClass) return nullptr;

    Il2CppClass *rootClass = g_api.object_get_class(gameSystems);
    if (rootClass == gooseClass) {
        how = "根对象本身就是 Goose.GooseGame";
        return gameSystems;
    }

    // First inspect direct reference fields typed or valued as GooseGame.
    for (FieldInfo *f : enumerateFields(rootClass)) {
        if (isStaticField(f)) continue;
        const std::string tn = typeName(f);
        if (tn.find("GooseGame") == std::string::npos) continue;
        Il2CppObject *value = nullptr;
        if (fieldObject(gameSystems, f, &value) && value) {
            if (g_api.object_get_class(value) == gooseClass) {
                how = "GameSystems." + fieldName(f);
                return value;
            }
        }
    }

    // Then scan List fields and test each element's runtime class.
    for (FieldInfo *f : enumerateFields(rootClass)) {
        if (isStaticField(f)) continue;
        const std::string tn = typeName(f);
        if (tn.find("List<") == std::string::npos && tn.find("List1") == std::string::npos && tn.find("List[") == std::string::npos) continue;
        Il2CppObject *list = nullptr;
        if (!fieldObject(gameSystems, f, &list) || !list || !looksLikeList(list)) continue;

        int32_t count = 0;
        if (!listCount(list, &count)) continue;
        count = std::max(0, std::min(count, 128));
        for (int32_t i = 0; i < count; ++i) {
            Il2CppObject *item = listItem(list, i);
            if (!item || !g_api.object_get_class) continue;
            if (g_api.object_get_class(item) == gooseClass) {
                how = "GameSystems." + fieldName(f) + "[" + std::to_string(i) + "]";
                return item;
            }
        }
    }

    return nullptr;
}

struct PlayerRow {
    std::string name;
    std::string faction;
    std::string career;
    std::string classLabel;
};

static bool readPlayerFieldByCandidates(Il2CppObject *player, const std::vector<const char*> &candidates, NSString **outString, int32_t *outInt, std::string *which) {
    if (outString) *outString = nil;
    if (outInt) *outInt = 0;
    if (which) which->clear();
    if (!player || !g_api.object_get_class) return false;

    for (Il2CppClass *k = g_api.object_get_class(player); k; k = g_api.class_get_parent ? g_api.class_get_parent(k) : nullptr) {
        for (const char *candidate : candidates) {
            FieldInfo *f = g_api.findField(k, candidate);
            if (!f || isStaticField(f)) continue;
            const std::string tn = typeName(f);
            if (tn.find("System.String") != std::string::npos || tn == "string") {
                NSString *s = fieldString(player, f);
                if (s.length) {
                    if (outString) *outString = s;
                    if (which) *which = candidate;
                    return true;
                }
            } else {
                int32_t v = 0;
                if (fieldI32(player, f, &v)) {
                    if (outInt) *outInt = v;
                    if (which) *which = candidate;
                    return true;
                }
            }
        }
    }
    return false;
}

static PlayerRow readPlayer(Il2CppObject *player) {
    PlayerRow row;
    if (!player || !g_api.object_get_class) return row;
    row.classLabel = g_api.classLabel(g_api.object_get_class(player));

    const std::vector<const char*> nameCandidates = {
        "Name","name","PlayerName","playerName","DisplayName","displayName",
        "Nickname","nickname","NickName","nickName","<Nickname>k__BackingField","<Name>k__BackingField","<PlayerName>k__BackingField"
    };
    const std::vector<const char*> factionCandidates = {
        "Faction","faction","Camp","camp","Team","team","FactionId","factionId",
        "CampId","campId","Side","side","SideId","sideId",
        "<Faction>k__BackingField","<FactionId>k__BackingField","<Camp>k__BackingField","<CampId>k__BackingField"
    };
    const std::vector<const char*> careerCandidates = {
        "Career","career","Profession","profession","Role","role","RoleId","roleId",
        "CareerId","careerId","ProfessionId","professionId","CurrentRole","currentRole",
        "<Role>k__BackingField","<RoleId>k__BackingField","<Career>k__BackingField","<CareerId>k__BackingField"
    };

    NSString *name = nil; std::string usedName;
    int32_t temp = 0; std::string usedFaction; std::string usedCareer;

    if (readPlayerFieldByCandidates(player, nameCandidates, &name, nullptr, &usedName) && name.length) {
        row.name = [name UTF8String] ? std::string([name UTF8String]) : "";
    }

    int32_t faction = -1;
    if (readPlayerFieldByCandidates(player, factionCandidates, nullptr, &faction, &usedFaction)) {
        row.faction = "ID=" + std::to_string(faction) + " (" + usedFaction + ")";
    }

    int32_t career = -1;
    if (readPlayerFieldByCandidates(player, careerCandidates, nullptr, &career, &usedCareer)) {
        row.career = "ID=" + std::to_string(career) + " (" + usedCareer + ")";
    }

    // One-level nested data fallback, matching structures observed in the supplied reference binary.
    Il2CppClass *pk = g_api.object_get_class(player);
    const char *nestedCandidates[] = {"GooseBaseData","gooseBaseData","UGCBaseData","ugcBaseData","BaseData","baseData","<GooseBaseData>k__BackingField","<UGCBaseData>k__BackingField"};
    for (const char *nestedName : nestedCandidates) {
        if (!row.name.empty()) break;
        FieldInfo *nestedField = g_api.findField(pk, nestedName);
        if (!nestedField || isStaticField(nestedField)) continue;
        Il2CppObject *nested = nullptr;
        if (!fieldObject(player, nestedField, &nested) || !nested || !g_api.object_get_class) continue;
        const std::vector<const char*> nestedNameCandidates = {"Nickname","nickname","NickName","nickName","Name","name","PlayerName","playerName","<Nickname>k__BackingField","<Name>k__BackingField"};
        NSString *nestedString = nil; std::string unused;
        if (readPlayerFieldByCandidates(nested, nestedNameCandidates, &nestedString, nullptr, &unused) && nestedString.length) {
            row.name = [nestedString UTF8String] ? std::string([nestedString UTF8String]) : "";
        }
    }

    return row;
}

static bool getPlayersDictionary(Il2CppObject *gooseGame, Il2CppObject **outDict, std::string &whichField) {
    if (outDict) *outDict = nullptr;
    whichField.clear();
    if (!gooseGame || !g_api.object_get_class) return false;
    Il2CppClass *klass = g_api.object_get_class(gooseGame);

    // Exact field from the supplied reference binary.
    FieldInfo *players = g_api.findField(klass, "players");
    if (!players) players = g_api.findField(klass, "Players");
    if (!players) players = g_api.findField(klass, "<players>k__BackingField");
    if (!players) players = g_api.findField(klass, "<Players>k__BackingField");
    if (players && !isStaticField(players)) {
        Il2CppObject *dict = nullptr;
        if (fieldObject(gooseGame, players, &dict) && dict && looksLikeDictionary(dict)) {
            if (outDict) *outDict = dict;
            whichField = "players";
            return true;
        }
    }

    // Safe fallback: inspect instance fields whose metadata says Dictionary and use only one whose values enumerate.
    for (FieldInfo *f : enumerateFields(klass)) {
        if (isStaticField(f)) continue;
        const std::string tn = typeName(f);
        if (tn.find("Dictionary<") == std::string::npos && tn.find("System.Collections.Generic.Dictionary") == std::string::npos) continue;
        Il2CppObject *dict = nullptr;
        if (!fieldObject(gooseGame, f, &dict) || !dict || !looksLikeDictionary(dict)) continue;
        if (outDict) *outDict = dict;
        whichField = fieldName(f);
        return true;
    }
    return false;
}

static std::vector<Il2CppObject *> enumerateDictionaryValues(Il2CppObject *dict, int maxPlayers, std::string &error) {
    error.clear();
    std::vector<Il2CppObject *> result;
    if (!dict || !g_api.object_get_class) { error = "Dictionary 对象为空"; return result; }
    maxPlayers = std::max(1, std::min(maxPlayers, 32));
    Il2CppClass *dictClass = g_api.object_get_class(dict);

    const MethodInfo *getValues = g_api.findMethod(dictClass, "get_Values", 0);
    if (!getValues) { error = "Dictionary.get_Values 未找到"; return result; }
    Il2CppObject *values = nullptr;
    if (!invokeNoArgObject(getValues, dict, &values) || !values) { error = "get_Values 调用失败"; return result; }

    Il2CppClass *valuesClass = g_api.object_get_class(values);
    const MethodInfo *getEnumerator = g_api.findMethod(valuesClass, "GetEnumerator", 0);
    if (!getEnumerator) { error = "ValueCollection.GetEnumerator 未找到"; return result; }
    Il2CppObject *enumerator = nullptr;
    if (!invokeNoArgObject(getEnumerator, values, &enumerator) || !enumerator) { error = "GetEnumerator 调用失败"; return result; }

    Il2CppClass *enumClass = g_api.object_get_class(enumerator);
    const MethodInfo *moveNext = g_api.findMethod(enumClass, "MoveNext", 0);
    const MethodInfo *current = g_api.findMethod(enumClass, "get_Current", 0);
    if (!moveNext || !current) { error = "Enumerator 方法未找到"; return result; }

    for (int i = 0; i < maxPlayers; ++i) {
        bool hasNext = false;
        if (!invokeBool(moveNext, enumerator, &hasNext)) { error = "MoveNext 调用失败"; break; }
        if (!hasNext) break;
        bool ok = false;
        Il2CppObject *player = invokeObject(current, enumerator, {}, &ok);
        if (!ok) { error = "Current 调用失败"; break; }
        if (player) result.push_back(player);
    }
    return result;
}

static std::string gameStatusLine(Il2CppObject *game) {
    if (!game || !g_api.object_get_class) return "game=null";
    return "game=" + g_api.classLabel(g_api.object_get_class(game));
}

@interface GGDScanController : NSObject
@property(nonatomic, readonly) BOOL scanning;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSArray<NSString *> *lines;
- (void)scanNow;
@end

@implementation GGDScanController {
    std::atomic_bool _scanning;
    NSString *_status;
    NSArray<NSString *> *_lines;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanning = false;
        _status = @"等待手动读取";
        _lines = @[];
    }
    return self;
}

- (BOOL)scanning { return _scanning.load(); }
- (NSString *)status { @synchronized(self) { return _status ?: @""; } }
- (NSArray<NSString *> *)lines { @synchronized(self) { return _lines ?: @[]; } }

- (void)publishStatus:(NSString *)status lines:(NSArray<NSString *> *)lines {
    @synchronized(self) {
        _status = [status copy];
        _lines = [lines copy];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"GGDScanUpdated" object:self];
    });
}

- (void)scanNow {
    bool expected = false;
    if (!_scanning.compare_exchange_strong(expected, true)) return;

    [self publishStatus:@"正在启动运行时检查…" lines:@[]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            std::string missing;
            {
                std::lock_guard<std::mutex> lock(g_apiMutex);
                if (!g_api.resolveAll(missing)) {
                    NSString *s = [NSString stringWithFormat:@"IL2CPP API 不完整：%s", missing.c_str()];
                    [self publishStatus:s lines:@[]];
                    _scanning.store(false);
                    return;
                }
            }

            [self publishStatus:@"IL2CPP API 已定位，正在挂载线程…" lines:@[]];
            if (!g_api.attach()) {
                [self publishStatus:@"IL2CPP 线程挂载失败" lines:@[]];
                _scanning.store(false);
                return;
            }

            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            NSString *gameClassText = @"";
            std::string gameHow;
            Il2CppObject *game = findStaticGameInstance(gameHow);
            if (!game) {
                [self publishStatus:@"找到 IL2CPP，但 Game 实例尚未出现" lines:@[]];
                _scanning.store(false);
                return;
            }

            gameClassText = [NSString stringWithUTF8String:gameStatusLine(game).c_str()] ?: @"";
            [lines addObject:[NSString stringWithFormat:@"Game 来源：%s", gameHow.c_str()]];
            [lines addObject:gameClassText];

            std::string gooseHow;
            Il2CppObject *gooseGame = findGooseGame(game, gooseHow);
            if (!gooseGame) {
                [self publishStatus:@"Game 已找到，但暂未找到 GooseGame" lines:lines];
                _scanning.store(false);
                return;
            }
            [lines addObject:[NSString stringWithFormat:@"GooseGame：%s", gooseHow.c_str()]];
            [lines addObject:[NSString stringWithUTF8String:gameStatusLine(gooseGame).c_str()] ?: @"GooseGame class=?"];

            Il2CppObject *dict = nullptr;
            std::string dictField;
            if (!getPlayersDictionary(gooseGame, &dict, dictField)) {
                [self publishStatus:@"GooseGame 已找到，但 players Dictionary 未找到" lines:lines];
                _scanning.store(false);
                return;
            }
            [lines addObject:[NSString stringWithFormat:@"玩家字段：%s", dictField.c_str()]];
            [lines addObject:[NSString stringWithUTF8String:g_api.classLabel(g_api.object_get_class(dict)).c_str()] ?: @"Dictionary class=?"];

            std::string enumError;
            std::vector<Il2CppObject *> players = enumerateDictionaryValues(dict, 32, enumError);
            [lines addObject:[NSString stringWithFormat:@"枚举玩家：%zu", players.size()]];
            if (!enumError.empty()) [lines addObject:[NSString stringWithUTF8String:("枚举提示：" + enumError).c_str()] ?: @"enumeration error"];

            for (size_t i = 0; i < players.size() && i < 12; ++i) {
                PlayerRow row = readPlayer(players[i]);
                NSString *name = row.name.empty() ? @"<未找到姓名字段>" : [NSString stringWithUTF8String:row.name.c_str()];
                NSString *faction = row.faction.empty() ? @"<未找到阵营字段>" : [NSString stringWithUTF8String:row.faction.c_str()];
                NSString *career = row.career.empty() ? @"<未找到职业字段>" : [NSString stringWithUTF8String:row.career.c_str()];
                NSString *klass = [NSString stringWithUTF8String:row.classLabel.c_str()] ?: @"?";
                [lines addObject:[NSString stringWithFormat:@"#%zu  %@ | %@ | %@", i + 1, name, faction, career]];
                if (i == 0) [lines addObject:[NSString stringWithFormat:@"玩家类：%@", klass]];
            }

            NSString *finalStatus = players.empty()
                ? @"players 已找到，但暂未枚举出玩家"
                : [NSString stringWithFormat:@"成功读取 %zu 名玩家", players.size()];
            [self publishStatus:finalStatus lines:lines];
            _scanning.store(false);
        }
    });
}

@end

@interface GGDOverlayView : UIView
@property(nonatomic, strong) UIButton *toggle;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIButton *scanButton;
@property(nonatomic, strong) GGDScanController *scanner;
@end

@implementation GGDOverlayView

- (instancetype)initWithFrame:(CGRect)frame scanner:(GGDScanController *)scanner {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.scanner = scanner;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;

    self.toggle = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggle.frame = CGRectMake(14, 120, 116, 42);
    self.toggle.layer.cornerRadius = 21;
    self.toggle.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.92];
    [self.toggle setTitle:@"GGD 已加载" forState:UIControlStateNormal];
    [self.toggle setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.toggle.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.toggle addTarget:self action:@selector(togglePanel:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggle];

    self.panel = [[UIView alloc] initWithFrame:CGRectMake(14, 168, 332, 300)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.94];
    self.panel.layer.cornerRadius = 14;
    self.panel.hidden = YES;
    [self addSubview:self.panel];

    self.label = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 304, 220)];
    self.label.textColor = UIColor.whiteColor;
    self.label.font = [UIFont systemFontOfSize:13];
    self.label.numberOfLines = 0;
    self.label.text = @"GGD Identity\n状态：等待手动读取";
    [self.panel addSubview:self.label];

    self.scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.scanButton.frame = CGRectMake(14, 245, 304, 40);
    self.scanButton.layer.cornerRadius = 10;
    self.scanButton.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    [self.scanButton setTitle:@"开始读取" forState:UIControlStateNormal];
    [self.scanButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.scanButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.scanButton addTarget:self action:@selector(scan:) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.scanButton];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scanUpdated:) name:@"GGDScanUpdated" object:scanner];
    return self;
}

- (void)togglePanel:(id)sender {
    self.panel.hidden = !self.panel.hidden;
}

- (void)scan:(id)sender {
    [self.scanner scanNow];
}

- (void)scanUpdated:(NSNotification *)note {
    NSString *status = self.scanner.status;
    NSArray<NSString *> *lines = self.scanner.lines;
    NSMutableString *text = [NSMutableString stringWithFormat:@"GGD Identity\n状态：%@", status ?: @""];
    for (NSString *line in lines) {
        [text appendFormat:@"\n%@", line];
    }
    self.label.text = text;
    self.scanButton.enabled = !self.scanner.scanning;
    [self.scanButton setTitle:(self.scanner.scanning ? @"读取中…" : @"重新读取") forState:UIControlStateNormal];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect a = self.toggle.frame;
    if (point.x >= a.origin.x && point.x <= a.origin.x + a.size.width &&
        point.y >= a.origin.y && point.y <= a.origin.y + a.size.height) return YES;
    if (!self.panel.hidden) {
        CGRect b = self.panel.frame;
        if (point.x >= b.origin.x && point.x <= b.origin.x + b.size.width &&
            point.y >= b.origin.y && point.y <= b.origin.y + b.size.height) return YES;
    }
    return NO;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

static UIWindow *GGDFindWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.alpha > 0.01 && w.windowLevel == UIWindowLevelNormal) {
                if (w.isKeyWindow) return w;
            }
        }
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.alpha > 0.01 && w.windowLevel == UIWindowLevelNormal) return w;
        }
    }
    return nil;
}

__attribute__((constructor))
static void GGDInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (int i = 0; i < 40 && !window; ++i) {
            window = GGDFindWindow();
            if (!window) [NSThread sleepForTimeInterval:0.15];
        }
        if (!window) return;

        GGDScanController *scanner = [GGDScanController new];
        GGDOverlayView *overlay = [[GGDOverlayView alloc] initWithFrame:window.bounds scanner:scanner];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:overlay];
    });
}
