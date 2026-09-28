#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>
#include <stdint.h>
#include <string.h>

// GGD Identity Overlay v7 - complete UI + target-specific player reader
// Target: com.seayoo.ggd / 1.1.13 / arm64 / iOS 18+
//
// UI goals:
//   - independent overlay UIWindow, not attached to the game's UIWindow
//   - draggable GGD bubble
//   - obvious manual "立即读取玩家" button
//   - optional 2-second auto refresh
//   - colored faction balls + faction + role + name + ID + UID
//   - game touches pass through outside the bubble/panel
//
// Runtime goals:
//   - IL2CPP is initialized only after a manual/auto read request
//   - scans execute on the main thread to avoid Unity/IL2CPP cross-thread object access
//   - target-specific offsets come from the supplied 1.1.13 reference analysis
//   - managed collection discovery is retained as a fallback

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
using t_object_get_class = Il2CppClass* (*)(Il2CppObject*);
using t_object_unbox = void* (*)(Il2CppObject*);
using t_runtime_invoke = Il2CppObject* (*)(const MethodInfo*, void*, void**, Il2CppException**);
using t_string_length = int32_t (*)(Il2CppString*);
using t_string_chars = const uint16_t* (*)(Il2CppString*);

static void *GGDResolve(void *handle, const char *name) {
    void *p = handle ? dlsym(handle, name) : nullptr;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

template <typename T>
static bool GGDResolveInto(T &slot, void *handle, const char *name) {
    void *p = GGDResolve(handle, name);
    if (!p) return false;
    slot = reinterpret_cast<T>(p);
    return true;
}

static void *GGDFindUnityHandle() {
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
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
    t_object_get_class object_get_class = nullptr;
    t_object_unbox object_unbox = nullptr;
    t_runtime_invoke runtime_invoke = nullptr;
    t_string_length string_length = nullptr;
    t_string_chars string_chars = nullptr;
    void *unityHandle = nullptr;
    bool ready = false;

    bool resolveAll(std::string &missing) {
        if (ready) return true;
        unityHandle = GGDFindUnityHandle();
        if (!unityHandle) {
            missing = "UnityFramework 未加载";
            return false;
        }

        struct Req { bool ok; const char *name; };
        const Req req[] = {
            {GGDResolveInto(domain_get, unityHandle, "il2cpp_domain_get"), "domain_get"},
            {GGDResolveInto(thread_attach, unityHandle, "il2cpp_thread_attach"), "thread_attach"},
            {GGDResolveInto(domain_get_assemblies, unityHandle, "il2cpp_domain_get_assemblies"), "domain_get_assemblies"},
            {GGDResolveInto(assembly_get_image, unityHandle, "il2cpp_assembly_get_image"), "assembly_get_image"},
            {GGDResolveInto(image_get_name, unityHandle, "il2cpp_image_get_name"), "image_get_name"},
            {GGDResolveInto(class_from_name, unityHandle, "il2cpp_class_from_name"), "class_from_name"},
            {GGDResolveInto(class_get_name, unityHandle, "il2cpp_class_get_name"), "class_get_name"},
            {GGDResolveInto(class_get_namespace, unityHandle, "il2cpp_class_get_namespace"), "class_get_namespace"},
            {GGDResolveInto(class_get_parent, unityHandle, "il2cpp_class_get_parent"), "class_get_parent"},
            {GGDResolveInto(class_get_fields, unityHandle, "il2cpp_class_get_fields"), "class_get_fields"},
            {GGDResolveInto(class_get_field, unityHandle, "il2cpp_class_get_field_from_name"), "class_get_field_from_name"},
            {GGDResolveInto(class_get_method, unityHandle, "il2cpp_class_get_method_from_name"), "class_get_method_from_name"},
            {GGDResolveInto(field_get_name, unityHandle, "il2cpp_field_get_name"), "field_get_name"},
            {GGDResolveInto(field_get_flags, unityHandle, "il2cpp_field_get_flags"), "field_get_flags"},
            {GGDResolveInto(field_get_type, unityHandle, "il2cpp_field_get_type"), "field_get_type"},
            {GGDResolveInto(field_get_value, unityHandle, "il2cpp_field_get_value"), "field_get_value"},
            {GGDResolveInto(field_get_value_object, unityHandle, "il2cpp_field_get_value_object"), "field_get_value_object"},
            {GGDResolveInto(field_static_get_value, unityHandle, "il2cpp_field_static_get_value"), "field_static_get_value"},
            {GGDResolveInto(type_get_name, unityHandle, "il2cpp_type_get_name"), "type_get_name"},
            {GGDResolveInto(object_get_class, unityHandle, "il2cpp_object_get_class"), "object_get_class"},
            {GGDResolveInto(object_unbox, unityHandle, "il2cpp_object_unbox"), "object_unbox"},
            {GGDResolveInto(runtime_invoke, unityHandle, "il2cpp_runtime_invoke"), "runtime_invoke"},
            {GGDResolveInto(string_length, unityHandle, "il2cpp_string_length"), "string_length"},
            {GGDResolveInto(string_chars, unityHandle, "il2cpp_string_chars"), "string_chars"}
        };

        missing.clear();
        for (const auto &r : req) {
            if (!r.ok) {
                if (!missing.empty()) missing += ", ";
                missing += r.name;
            }
        }
        ready = missing.empty();
        return ready;
    }

    bool attach() const {
        if (!domain_get || !thread_attach) return false;
        Il2CppDomain *domain = domain_get();
        if (!domain) return false;
        return thread_attach(domain) != nullptr;
    }

    Il2CppClass *findClass(const char *ns, const char *name) const {
        if (!ns || !name || !domain_get || !domain_get_assemblies || !assembly_get_image || !class_from_name) return nullptr;
        Il2CppDomain *domain = domain_get();
        if (!domain) return nullptr;
        size_t count = 0;
        const Il2CppAssembly **assemblies = domain_get_assemblies(domain, &count);
        if (!assemblies || count == 0 || count > 4096) return nullptr;
        for (size_t i = 0; i < count; ++i) {
            if (!assemblies[i]) continue;
            const Il2CppImage *image = assembly_get_image(assemblies[i]);
            if (!image) continue;
            Il2CppClass *klass = class_from_name(image, ns, name);
            if (klass) return klass;
        }
        return nullptr;
    }

    Il2CppClass *findAnyClass(const std::vector<std::pair<std::string, std::string>> &candidates) const {
        for (const auto &pair : candidates) {
            if (Il2CppClass *klass = findClass(pair.first.c_str(), pair.second.c_str())) return klass;
        }
        return nullptr;
    }

    std::string classLabel(Il2CppClass *klass) const {
        if (!klass || !class_get_name) return "?";
        const char *name = class_get_name(klass);
        const char *ns = class_get_namespace ? class_get_namespace(klass) : nullptr;
        if (name && ns && *ns) return std::string(ns) + "." + name;
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

static GGDIl2CppAPI gAPI;
static std::mutex gAPIMutex;

static bool GGDSafeRead(uintptr_t address, void *out, size_t size) {
    if (!address || !out || size == 0 || size > 0x1000) return false;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                          (vm_address_t)address,
                                          (vm_size_t)size,
                                          (vm_address_t)out,
                                          &copied);
    return kr == KERN_SUCCESS && copied == size;
}

static bool GGDSafePtr(uintptr_t address, uintptr_t *out) {
    uint64_t value = 0;
    if (!GGDSafeRead(address, &value, sizeof(value))) return false;
    if (out) *out = (uintptr_t)value;
    return value != 0;
}

static bool GGDSafeI32(uintptr_t address, int32_t *out) {
    int32_t value = 0;
    if (!GGDSafeRead(address, &value, sizeof(value))) return false;
    if (out) *out = value;
    return true;
}

static bool GGDSafeU64(uintptr_t address, uint64_t *out) {
    uint64_t value = 0;
    if (!GGDSafeRead(address, &value, sizeof(value))) return false;
    if (out) *out = value;
    return true;
}

static bool GGDReadManagedStringRaw(uintptr_t stringPtr, NSString **out) {
    if (out) *out = nil;
    if (!stringPtr) return false;

    int32_t length = 0;
    if (!GGDSafeI32(stringPtr + 0x10, &length)) return false;
    if (length < 0 || length > 96) return false;
    if (length == 0) {
        if (out) *out = @"";
        return true;
    }

    std::vector<uint16_t> chars((size_t)length);
    if (!GGDSafeRead(stringPtr + 0x14, chars.data(), chars.size() * sizeof(uint16_t))) return false;
    NSString *value = [[NSString alloc] initWithCharacters:(const unichar *)chars.data() length:(NSUInteger)length];
    if (out) *out = value;
    return value != nil;
}

static bool GGDSafeManagedString(Il2CppString *stringObj, NSString **out) {
    if (out) *out = nil;
    if (!stringObj) return false;
    if (gAPI.string_length && gAPI.string_chars) {
        int32_t length = gAPI.string_length(stringObj);
        if (length >= 0 && length <= 96) {
            if (length == 0) { if (out) *out = @""; return true; }
            const uint16_t *chars = gAPI.string_chars(stringObj);
            if (chars) {
                NSString *value = [[NSString alloc] initWithCharacters:(const unichar *)chars length:(NSUInteger)length];
                if (out) *out = value;
                return value != nil;
            }
        }
    }
    return GGDReadManagedStringRaw((uintptr_t)stringObj, out);
}

static bool GGDFindBaseData(uintptr_t player, uintptr_t *outBase) {
    if (outBase) *outBase = 0;
    if (!player) return false;

    const uintptr_t candidates[] = {0x160, 0x150};
    for (uintptr_t offset : candidates) {
        uintptr_t base = 0;
        if (!GGDSafePtr(player + offset, &base) || !base) continue;

        // Reference layout: BaseData+0x18 is managed nickname and BaseData+0x38 is UID-like.
        NSString *probe = nil;
        uint64_t uidProbe = 0;
        bool stringOkay = GGDReadManagedStringRaw(base + 0x18, &probe);
        bool uidOkay = GGDSafeU64(base + 0x38, &uidProbe);
        if (stringOkay || uidOkay) {
            if (outBase) *outBase = base;
            return true;
        }
    }
    return false;
}

static std::vector<FieldInfo *> GGDEnumerateFields(Il2CppClass *klass) {
    std::vector<FieldInfo *> result;
    if (!klass || !gAPI.class_get_fields) return result;
    for (Il2CppClass *cursor = klass; cursor; cursor = gAPI.class_get_parent ? gAPI.class_get_parent(cursor) : nullptr) {
        void *iter = nullptr;
        for (int guard = 0; guard < 512; ++guard) {
            FieldInfo *field = gAPI.class_get_fields(cursor, &iter);
            if (!field) break;
            result.push_back(field);
        }
    }
    return result;
}

static bool GGDIsStaticField(FieldInfo *field) {
    return field && gAPI.field_get_flags && ((gAPI.field_get_flags(field) & 0x10u) != 0u);
}

static std::string GGDFieldName(FieldInfo *field) {
    const char *name = (field && gAPI.field_get_name) ? gAPI.field_get_name(field) : nullptr;
    return name ? std::string(name) : "?";
}

static std::string GGDFieldType(FieldInfo *field) {
    if (!field || !gAPI.field_get_type || !gAPI.type_get_name) return "?";
    const Il2CppType *type = gAPI.field_get_type(field);
    const char *name = type ? gAPI.type_get_name(type) : nullptr;
    return name ? std::string(name) : "?";
}

static bool GGDFieldObject(Il2CppObject *object, FieldInfo *field, Il2CppObject **out) {
    if (out) *out = nullptr;
    if (!object || !field || !gAPI.field_get_value) return false;
    Il2CppObject *value = nullptr;
    gAPI.field_get_value(object, field, &value);
    if (out) *out = value;
    return true;
}

static Il2CppObject *GGDFieldValueObject(Il2CppObject *object, FieldInfo *field) {
    if (!object || !field || !gAPI.field_get_value_object) return nullptr;
    return gAPI.field_get_value_object(field, object);
}

static bool GGDFieldString(Il2CppObject *object, FieldInfo *field, NSString **out) {
    if (out) *out = nil;
    Il2CppObject *raw = GGDFieldValueObject(object, field);
    if (!raw) return false;
    return GGDSafeManagedString((Il2CppString *)raw, out);
}

static bool GGDBoxedI32(Il2CppObject *boxed, int32_t *out) {
    if (out) *out = 0;
    if (!boxed || !gAPI.object_unbox) return false;
    void *p = gAPI.object_unbox(boxed);
    if (!p) return false;
    int32_t value = 0;
    memcpy(&value, p, sizeof(value));
    if (out) *out = value;
    return true;
}

static bool GGDFieldI32(Il2CppObject *object, FieldInfo *field, int32_t *out) {
    return GGDBoxedI32(GGDFieldValueObject(object, field), out);
}

static Il2CppObject *GGDInvokeObject(const MethodInfo *method, Il2CppObject *instance, std::vector<void *> params, bool *okOut) {
    if (okOut) *okOut = false;
    if (!method || !gAPI.runtime_invoke) return nullptr;
    Il2CppException *exception = nullptr;
    void **paramPtr = params.empty() ? nullptr : params.data();
    Il2CppObject *result = gAPI.runtime_invoke(method, instance, paramPtr, &exception);
    if (exception) return nullptr;
    if (okOut) *okOut = true;
    return result;
}

static bool GGDInvokeBool(const MethodInfo *method, Il2CppObject *instance, bool *out) {
    if (out) *out = false;
    bool ok = false;
    Il2CppObject *boxed = GGDInvokeObject(method, instance, {}, &ok);
    if (!ok || !boxed || !gAPI.object_unbox) return false;
    void *p = gAPI.object_unbox(boxed);
    if (!p) return false;
    uint8_t value = 0;
    memcpy(&value, p, sizeof(value));
    if (out) *out = value != 0;
    return true;
}

static bool GGDInvokeI32(const MethodInfo *method, Il2CppObject *instance, int32_t *out) {
    if (out) *out = 0;
    bool ok = false;
    Il2CppObject *boxed = GGDInvokeObject(method, instance, {}, &ok);
    return ok && GGDBoxedI32(boxed, out);
}

static bool GGDInvokeNoArgObject(const MethodInfo *method, Il2CppObject *instance, Il2CppObject **out) {
    if (out) *out = nullptr;
    bool ok = false;
    Il2CppObject *result = GGDInvokeObject(method, instance, {}, &ok);
    if (out) *out = result;
    return ok;
}

static Il2CppObject *GGDListItem(Il2CppObject *list, int32_t index) {
    if (!list || !gAPI.object_get_class) return nullptr;
    Il2CppClass *klass = gAPI.object_get_class(list);
    const MethodInfo *method = gAPI.findMethod(klass, "get_Item", 1);
    if (!method) return nullptr;
    int32_t arg = index;
    bool ok = false;
    return GGDInvokeObject(method, list, {&arg}, &ok);
}

static bool GGDListCount(Il2CppObject *list, int32_t *out) {
    if (out) *out = 0;
    if (!list || !gAPI.object_get_class) return false;
    Il2CppClass *klass = gAPI.object_get_class(list);
    const MethodInfo *method = gAPI.findMethod(klass, "get_Count", 0);
    return GGDInvokeI32(method, list, out);
}

static bool GGDLooksLikeList(Il2CppObject *object) {
    if (!object || !gAPI.object_get_class) return false;
    std::string label = gAPI.classLabel(gAPI.object_get_class(object));
    return label.find("System.Collections.Generic.List") != std::string::npos || label.find("List<") != std::string::npos;
}

static bool GGDLooksLikeDictionary(Il2CppObject *object) {
    if (!object || !gAPI.object_get_class) return false;
    std::string label = gAPI.classLabel(gAPI.object_get_class(object));
    return label.find("System.Collections.Generic.Dictionary") != std::string::npos || label.find("Dictionary<") != std::string::npos;
}

static Il2CppObject *GGDFindStaticGameInstance(std::string &how) {
    how.clear();
    Il2CppClass *klass = gAPI.findAnyClass({
        {"Goose.Guidance", "Tutorial"},
        {"Adam.Gameplay", "App"},
        {"", "Tutorial"},
        {"", "App"}
    });
    if (!klass) return nullptr;

    for (FieldInfo *field : GGDEnumerateFields(klass)) {
        if (!GGDIsStaticField(field)) continue;
        std::string name = GGDFieldName(field);
        if (name != "<Game>k__BackingField" && name != "game" && name != "Game") continue;
        Il2CppObject *value = nullptr;
        if (gAPI.field_static_get_value) gAPI.field_static_get_value(field, &value);
        if (value) {
            how = std::string("静态 ") + name;
            return value;
        }
    }
    return nullptr;
}

static Il2CppObject *GGDFindGooseGame(Il2CppObject *root, std::string &how) {
    how.clear();
    if (!root || !gAPI.object_get_class) return nullptr;

    Il2CppClass *gooseClass = gAPI.findAnyClass({
        {"Goose", "GooseGame"},
        {"", "GooseGame"}
    });
    if (!gooseClass) return nullptr;

    if (gAPI.object_get_class(root) == gooseClass) {
        how = "Game 本身";
        return root;
    }

    Il2CppClass *rootClass = gAPI.object_get_class(root);

    // Target-specific GameSystems raw list fallback: GameSystems+0x40 -> List<...>.
    uintptr_t rawListPtr = 0;
    if (GGDSafePtr((uintptr_t)root + 0x40, &rawListPtr) && rawListPtr) {
        Il2CppObject *list = (Il2CppObject *)rawListPtr;
        if (GGDLooksLikeList(list)) {
            int32_t count = 0;
            if (GGDListCount(list, &count)) {
                count = std::max(0, std::min(count, 128));
                for (int32_t i = 0; i < count; ++i) {
                    Il2CppObject *item = GGDListItem(list, i);
                    if (item && gAPI.object_get_class(item) == gooseClass) {
                        how = "GameSystems+0x40";
                        return item;
                    }
                }
            }
        }
    }

    // Direct GooseGame reference fields.
    for (FieldInfo *field : GGDEnumerateFields(rootClass)) {
        if (GGDIsStaticField(field)) continue;
        if (GGDFieldType(field).find("GooseGame") == std::string::npos) continue;
        Il2CppObject *value = nullptr;
        if (GGDFieldObject(root, field, &value) && value && gAPI.object_get_class(value) == gooseClass) {
            how = std::string("字段 ") + GGDFieldName(field);
            return value;
        }
    }

    // List fields as a safe metadata fallback.
    for (FieldInfo *field : GGDEnumerateFields(rootClass)) {
        if (GGDIsStaticField(field)) continue;
        std::string fieldType = GGDFieldType(field);
        if (fieldType.find("List<") == std::string::npos && fieldType.find("System.Collections.Generic.List") == std::string::npos) continue;
        Il2CppObject *list = nullptr;
        if (!GGDFieldObject(root, field, &list) || !list || !GGDLooksLikeList(list)) continue;
        int32_t count = 0;
        if (!GGDListCount(list, &count)) continue;
        count = std::max(0, std::min(count, 128));
        for (int32_t i = 0; i < count; ++i) {
            Il2CppObject *item = GGDListItem(list, i);
            if (item && gAPI.object_get_class(item) == gooseClass) {
                how = std::string("列表 ") + GGDFieldName(field) + "[" + std::to_string(i) + "]";
                return item;
            }
        }
    }
    return nullptr;
}

static Il2CppObject *GGDFindPlayersDictionary(Il2CppObject *gooseGame, std::string &how) {
    how.clear();
    if (!gooseGame || !gAPI.object_get_class) return nullptr;

    // Exact target field discovered in the supplied 1.1.13 reference layout.
    uintptr_t rawPlayers = 0;
    if (GGDSafePtr((uintptr_t)gooseGame + 0x40, &rawPlayers) && rawPlayers) {
        Il2CppObject *dict = (Il2CppObject *)rawPlayers;
        if (GGDLooksLikeDictionary(dict)) {
            how = "GooseGame+0x40 (players)";
            return dict;
        }
    }

    Il2CppClass *klass = gAPI.object_get_class(gooseGame);
    const char *exactNames[] = {"players", "Players", "<players>k__BackingField", "<Players>k__BackingField"};
    for (const char *name : exactNames) {
        FieldInfo *field = gAPI.findField(klass, name);
        if (!field || GGDIsStaticField(field)) continue;
        Il2CppObject *dict = nullptr;
        if (GGDFieldObject(gooseGame, field, &dict) && dict && GGDLooksLikeDictionary(dict)) {
            how = std::string("字段 ") + name;
            return dict;
        }
    }

    // Metadata fallback for builds where the backing field name changes.
    for (FieldInfo *field : GGDEnumerateFields(klass)) {
        if (GGDIsStaticField(field)) continue;
        std::string type = GGDFieldType(field);
        if (type.find("Dictionary<") == std::string::npos && type.find("System.Collections.Generic.Dictionary") == std::string::npos) continue;
        Il2CppObject *dict = nullptr;
        if (GGDFieldObject(gooseGame, field, &dict) && dict && GGDLooksLikeDictionary(dict)) {
            how = std::string("字典字段 ") + GGDFieldName(field);
            return dict;
        }
    }
    return nullptr;
}

static std::vector<Il2CppObject *> GGDEnumerateDictionaryValues(Il2CppObject *dict, int maxValues, std::string &error) {
    error.clear();
    std::vector<Il2CppObject *> result;
    if (!dict || !gAPI.object_get_class) {
        error = "Dictionary 为空";
        return result;
    }
    maxValues = std::max(1, std::min(maxValues, 32));
    Il2CppClass *dictClass = gAPI.object_get_class(dict);

    const MethodInfo *getValues = gAPI.findMethod(dictClass, "get_Values", 0);
    if (!getValues) {
        error = "get_Values 未找到";
        return result;
    }
    Il2CppObject *values = nullptr;
    if (!GGDInvokeNoArgObject(getValues, dict, &values) || !values) {
        error = "get_Values 调用失败";
        return result;
    }

    Il2CppClass *valuesClass = gAPI.object_get_class(values);
    const MethodInfo *getEnumerator = gAPI.findMethod(valuesClass, "GetEnumerator", 0);
    if (!getEnumerator) {
        error = "ValueCollection.GetEnumerator 未找到";
        return result;
    }
    Il2CppObject *enumerator = nullptr;
    if (!GGDInvokeNoArgObject(getEnumerator, values, &enumerator) || !enumerator) {
        error = "GetEnumerator 调用失败";
        return result;
    }

    Il2CppClass *enumClass = gAPI.object_get_class(enumerator);
    const MethodInfo *moveNext = gAPI.findMethod(enumClass, "MoveNext", 0);
    const MethodInfo *current = gAPI.findMethod(enumClass, "get_Current", 0);
    if (!moveNext || !current) {
        error = "Enumerator 方法未找到";
        return result;
    }

    std::unordered_set<uintptr_t> seen;
    for (int i = 0; i < maxValues; ++i) {
        bool hasNext = false;
        if (!GGDInvokeBool(moveNext, enumerator, &hasNext)) {
            error = "MoveNext 调用失败";
            break;
        }
        if (!hasNext) break;
        bool ok = false;
        Il2CppObject *player = GGDInvokeObject(current, enumerator, {}, &ok);
        if (!ok) {
            error = "Current 调用失败";
            break;
        }
        if (player && seen.insert((uintptr_t)player).second) result.push_back(player);
    }
    return result;
}

static NSString *GGDStringFromRaw(NSString *value) {
    return value.length ? value : @"";
}

static NSString *GGDFactionName(int32_t faction) {
    switch (faction) {
        case 1: return @"鹅";
        case 2: return @"鸭";
        case 3: return @"中立";
        default: return @"未知";
    }
}

static NSString *GGDRoleName(int32_t role) {
    switch (role) {
        case 0: return @"无";
        case 1: return @"鹅";
        case 2: return @"警长";
        case 3: return @"正义使者";
        case 4: return @"工程师";
        case 6: return @"侦探";
        case 7: return @"星界行者";
        case 8: return @"观察者";
        case 9: return @"跟踪者";
        case 10: return @"加拿大鹅";
        case 11: return @"殡仪员";
        case 12: return @"模仿鸭";
        case 13: return @"复仇者";
        case 14: return @"士兵";
        case 15: return @"法医";
        case 16: return @"探险家";
        case 17: return @"肉汁";
        case 19: return @"游说者";
        case 101: return @"鸭";
        case 102: return @"专业杀手";
        case 103: return @"隐形鸭";
        case 104: return @"变形者";
        case 105: return @"爆炸王";
        case 106: return @"刺客";
        case 107: return @"食鸟鸭";
        case 108: return @"巫医";
        case 109: return @"掠夺者";
        case 110: return @"狙击手";
        case 111: return @"小丑";
        case 112: return @"超能力者";
        case 113: return @"投毒者";
        case 114: return @"投毒者";
        case 117: return @"丘比特";
        case 201: return @"呆呆鸟";
        case 202: return @"鸽子";
        case 203: return @"鹈鹕";
        case 204: return @"猎鹰";
        case 205: return @"秃鹫";
        case 206: return @"决斗呆呆鸟";
        case 207: return @"杜鹃";
        case 208: return @"金鸡";
        case 209: return @"渡鸦";
        case 210: return @"喜鹊";
        case 901: return @"双面人";
        case 1093: return @"监视者";
        default: return [NSString stringWithFormat:@"未知角色 (ID %d)", role];
    }
}

static UIColor *GGDFactionColor(int32_t faction) {
    switch (faction) {
        case 1: return [UIColor colorWithRed:0.28 green:0.88 blue:0.46 alpha:1.0];
        case 2: return [UIColor colorWithRed:1.00 green:0.30 blue:0.30 alpha:1.0];
        case 3: return [UIColor colorWithRed:0.98 green:0.75 blue:0.20 alpha:1.0];
        default: return [UIColor colorWithWhite:0.62 alpha:1.0];
    }
}

struct GGDPlayerInfo {
    uintptr_t object = 0;
    std::string name;
    uint64_t uid = 0;
    int32_t displayID = -1;
    int32_t faction = 0;
    int32_t role = -1;
};

static GGDPlayerInfo GGDReadPlayer(uintptr_t player) {
    GGDPlayerInfo info;
    info.object = player;
    if (!player) return info;

    uintptr_t base = 0;
    GGDFindBaseData(player, &base);

    NSString *name = nil;
    if (base) GGDReadManagedStringRaw(base + 0x18, &name);
    if (!name.length) GGDReadManagedStringRaw(player + 0x1E0, &name);
    if (name.length) {
        const char *utf8 = [name UTF8String];
        if (utf8) info.name = utf8;
    }

    int32_t value = -1;
    if (base && GGDSafeI32(base + 0x188, &value) && value >= 0 && value <= 100000) {
        info.displayID = value;
    }

    int32_t faction = -1;
    if (GGDSafeI32(player + 0x128, &faction) && faction >= 0 && faction <= 3) {
        info.faction = faction;
    } else if (GGDSafeI32(player + 0x1EC, &faction) && faction >= 0 && faction <= 3) {
        info.faction = faction;
    }

    int32_t role = -1;
    if (GGDSafeI32(player + 0x24C, &role) && role >= 0 && role <= 20000) {
        info.role = role;
    }

    uint64_t uid = 0;
    if (base && GGDSafeU64(base + 0x110, &uid) && uid != 0) {
        info.uid = uid;
    } else if (base && GGDSafeU64(base + 0x38, &uid) && uid != 0) {
        info.uid = uid;
    } else if (GGDSafeU64(player + 0x110, &uid) && uid != 0) {
        info.uid = uid;
    }

    return info;
}

static bool GGDPlayerLooksValid(const GGDPlayerInfo &info) {
    return info.object != 0 && (!info.name.empty() || info.uid != 0 || info.displayID >= 0 || info.role >= 0 || info.faction != 0);
}

@interface GGDPlayerSnapshot : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *faction;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *uid;
@property(nonatomic, assign) NSInteger displayID;
@property(nonatomic, assign) NSInteger factionID;
@property(nonatomic, assign) NSInteger roleID;
@end

@implementation GGDPlayerSnapshot
@end

@interface GGDScanController : NSObject
@property(nonatomic, readonly) BOOL scanning;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSArray<GGDPlayerSnapshot *> *players;
- (void)scanNow;
@end

@implementation GGDScanController {
    std::atomic_bool _scanning;
    NSString *_status;
    NSArray<GGDPlayerSnapshot *> *_players;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanning = false;
        _status = @"等待手动读取";
        _players = @[];
    }
    return self;
}

- (BOOL)scanning { return _scanning.load(); }
- (NSString *)status { @synchronized(self) { return _status ?: @""; } }
- (NSArray<GGDPlayerSnapshot *> *)players { @synchronized(self) { return _players ?: @[]; } }

- (void)publishStatus:(NSString *)status players:(NSArray<GGDPlayerSnapshot *> *)players {
    @synchronized(self) {
        _status = [status copy];
        if (players) _players = [players copy];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"GGDScanUpdated" object:self];
}

- (void)scanNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self scanNow]; });
        return;
    }

    bool expected = false;
    if (!_scanning.compare_exchange_strong(expected, true)) return;

    [self publishStatus:@"正在读取玩家…" players:self.players];

    @autoreleasepool {
        std::string missing;
        {
            std::lock_guard<std::mutex> lock(gAPIMutex);
            if (!gAPI.resolveAll(missing)) {
                [self publishStatus:[NSString stringWithFormat:@"运行时未就绪：%s", missing.c_str()] players:self.players];
                _scanning.store(false);
                return;
            }
        }

        if (!gAPI.attach()) {
            [self publishStatus:@"IL2CPP 线程挂载失败" players:self.players];
            _scanning.store(false);
            return;
        }

        std::string gameHow;
        Il2CppObject *game = GGDFindStaticGameInstance(gameHow);
        if (!game) {
            [self publishStatus:@"未找到 Game 实例：请在进入对局后点击读取" players:@[]];
            _scanning.store(false);
            return;
        }

        std::string gooseHow;
        Il2CppObject *gooseGame = GGDFindGooseGame(game, gooseHow);
        if (!gooseGame) {
            [self publishStatus:@"已找到 Game，但未找到 GooseGame" players:@[]];
            _scanning.store(false);
            return;
        }

        std::string dictHow;
        Il2CppObject *playersDict = GGDFindPlayersDictionary(gooseGame, dictHow);
        if (!playersDict) {
            [self publishStatus:@"已找到 GooseGame，但未找到 players" players:@[]];
            _scanning.store(false);
            return;
        }

        std::string enumError;
        std::vector<Il2CppObject *> rawPlayers = GGDEnumerateDictionaryValues(playersDict, 32, enumError);
        NSMutableArray<GGDPlayerSnapshot *> *snapshots = [NSMutableArray arrayWithCapacity:rawPlayers.size()];

        for (Il2CppObject *rawPlayer : rawPlayers) {
            GGDPlayerInfo info = GGDReadPlayer((uintptr_t)rawPlayer);
            if (!GGDPlayerLooksValid(info)) continue;

            GGDPlayerSnapshot *snapshot = [GGDPlayerSnapshot new];
            snapshot.name = info.name.empty() ? @"未知玩家" : [NSString stringWithUTF8String:info.name.c_str()];
            if (!snapshot.name.length) snapshot.name = @"未知玩家";
            snapshot.factionID = info.faction;
            snapshot.roleID = info.role;
            snapshot.faction = GGDFactionName(info.faction);
            snapshot.role = GGDRoleName(info.role);
            snapshot.displayID = info.displayID;
            snapshot.uid = info.uid ? [NSString stringWithFormat:@"%llu", (unsigned long long)info.uid] : @"-";
            [snapshots addObject:snapshot];
        }

        NSMutableString *status = [NSMutableString stringWithFormat:@"读取完成：%lu 名玩家", (unsigned long)snapshots.count];
        if (!enumError.empty()) [status appendFormat:@" · %@", [NSString stringWithUTF8String:enumError.c_str()] ?: @""];
        if (snapshots.count == 0) {
            [status setString:@"players 已找到，但当前没有可显示的玩家对象"];
        }

        [self publishStatus:status players:snapshots];
    }

    _scanning.store(false);
}

@end

static BOOL GGDPointInRect(CGPoint p, CGRect r) {
    return p.x >= r.origin.x && p.x <= r.origin.x + r.size.width &&
           p.y >= r.origin.y && p.y <= r.origin.y + r.size.height;
}

@interface GGDBubbleView : UIView
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *dotLabel;
@property(nonatomic, copy) void (^tapBlock)(void);
@property(nonatomic, copy) void (^dragBlock)(CGPoint);
@end

@implementation GGDBubbleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.055 alpha:0.94];
    self.layer.cornerRadius = 23.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.25;
    self.layer.shadowRadius = 6.0;
    self.layer.shadowOffset = CGSizeMake(0, 2);
    self.userInteractionEnabled = YES;

    _dotLabel = [[UILabel alloc] initWithFrame:CGRectMake(11, 14, 18, 18)];
    _dotLabel.text = @"●";
    _dotLabel.textColor = [UIColor colorWithRed:0.25 green:0.92 blue:0.52 alpha:1];
    _dotLabel.font = [UIFont boldSystemFontOfSize:13];
    _dotLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_dotLabel];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 10, 50, 28)];
    _titleLabel.text = @"GGD";
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont boldSystemFontOfSize:15];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_titleLabel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.superview];
        self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        [gesture setTranslation:CGPointMake(0, 0) inView:self.superview];
        if (self.dragBlock) self.dragBlock(self.center);
    }
}

- (void)handleTap:(id)sender {
    if (self.tapBlock) self.tapBlock();
}

@end

@interface GGDPlayerRowView : UIView
@property(nonatomic, strong) UIView *ball;
@property(nonatomic, strong) UILabel *topLabel;
@property(nonatomic, strong) UILabel *bottomLabel;
- (void)applySnapshot:(GGDPlayerSnapshot *)snapshot;
@end

@implementation GGDPlayerRowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    self.layer.cornerRadius = 10.0;

    _ball = [[UIView alloc] initWithFrame:CGRectMake(10, 20, 16, 16)];
    _ball.layer.cornerRadius = 8;
    [self addSubview:_ball];

    _topLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 8, 280, 26)];
    _topLabel.textColor = UIColor.whiteColor;
    _topLabel.font = [UIFont boldSystemFontOfSize:14];
    [self addSubview:_topLabel];

    _bottomLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 31, 280, 20)];
    _bottomLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    _bottomLabel.font = [UIFont systemFontOfSize:11];
    [self addSubview:_bottomLabel];
    return self;
}

- (void)applySnapshot:(GGDPlayerSnapshot *)snapshot {
    self.ball.backgroundColor = GGDFactionColor((int32_t)snapshot.factionID);
    NSString *name = snapshot.name.length ? snapshot.name : @"未知玩家";
    NSString *faction = snapshot.faction.length ? snapshot.faction : @"未知";
    NSString *role = snapshot.role.length ? snapshot.role : @"未知角色";
    self.topLabel.text = [NSString stringWithFormat:@"%@  ·  %@  ·  %@", faction, role, name];
    NSString *idText = snapshot.displayID >= 0 ? [NSString stringWithFormat:@"ID %ld", (long)snapshot.displayID] : @"ID -";
    NSString *uidText = snapshot.uid.length ? snapshot.uid : @"-";
    self.bottomLabel.text = [NSString stringWithFormat:@"%@    UID %@", idText, uidText];
}

@end

@interface GGDPanelView : UIView
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *readButton;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UISwitch *autoSwitch;
@property(nonatomic, strong) UILabel *autoLabel;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) GGDScanController *scanner;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) void (^closeBlock)(void);
@end

@implementation GGDPanelView

- (instancetype)initWithFrame:(CGRect)frame scanner:(GGDScanController *)scanner {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.scanner = scanner;
    self.backgroundColor = [UIColor colorWithWhite:0.045 alpha:0.96];
    self.layer.cornerRadius = 16;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.30;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, 5);

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 210, 28)];
    _titleLabel.text = @"GGD 玩家信息";
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self addSubview:_titleLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, 300, 36)];
    _statusLabel.text = @"等待手动读取";
    _statusLabel.textColor = [UIColor colorWithWhite:0.70 alpha:1];
    _statusLabel.font = [UIFont systemFontOfSize:11];
    _statusLabel.numberOfLines = 2;
    [self addSubview:_statusLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.frame = CGRectMake(285, 10, 42, 34);
    [_closeButton setTitle:@"×" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor colorWithWhite:0.80 alpha:1] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [_closeButton addTarget:self action:@selector(closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeButton];

    _readButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _readButton.frame = CGRectMake(16, 82, 311, 42);
    _readButton.layer.cornerRadius = 10;
    _readButton.backgroundColor = [UIColor colorWithRed:0.17 green:0.43 blue:0.86 alpha:1];
    [_readButton setTitle:@"立即读取玩家" forState:UIControlStateNormal];
    [_readButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _readButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_readButton addTarget:self action:@selector(readTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_readButton];

    _autoLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 132, 150, 28)];
    _autoLabel.text = @"自动刷新（2秒）";
    _autoLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    _autoLabel.font = [UIFont systemFontOfSize:12];
    [self addSubview:_autoLabel];

    _autoSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(264, 130, 51, 31)];
    _autoSwitch.on = NO;
    [_autoSwitch addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_autoSwitch];

    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(16, 166, 311, 280)];
    _scrollView.backgroundColor = UIColor.clearColor;
    _scrollView.alwaysBounceVertical = YES;
    [self addSubview:_scrollView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scanUpdated:) name:@"GGDScanUpdated" object:scanner];
    return self;
}

- (void)readTapped:(id)sender {
    [self.scanner scanNow];
}

- (void)autoChanged:(UISwitch *)sender {
    [self.timer invalidate];
    self.timer = nil;
    if (sender.isOn) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(autoTick:) userInfo:nil repeats:YES];
    }
}

- (void)autoTick:(NSTimer *)timer {
    if (!self.scanner.scanning) [self.scanner scanNow];
}

- (void)closeTapped:(id)sender {
    if (self.closeBlock) self.closeBlock();
}

- (void)scanUpdated:(NSNotification *)note {
    self.statusLabel.text = self.scanner.status;
    self.readButton.enabled = !self.scanner.scanning;
    self.readButton.alpha = self.scanner.scanning ? 0.55 : 1.0;
    [self.readButton setTitle:(self.scanner.scanning ? @"读取中…" : @"立即读取玩家") forState:UIControlStateNormal];

    for (UIView *view in [self.scrollView.subviews copy]) [view removeFromSuperview];
    NSArray<GGDPlayerSnapshot *> *players = self.scanner.players;
    CGFloat y = 0;
    for (GGDPlayerSnapshot *snapshot in players) {
        GGDPlayerRowView *row = [[GGDPlayerRowView alloc] initWithFrame:CGRectMake(0, y, 311, 58)];
        [row applySnapshot:snapshot];
        [self.scrollView addSubview:row];
        y += 64;
    }
    self.scrollView.contentSize = CGSizeMake(311, MAX(y, 1));
}

- (void)dealloc {
    [self.timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

@interface GGDOverlayRootView : UIView
@property(nonatomic, strong) GGDBubbleView *bubble;
@property(nonatomic, strong) GGDPanelView *panel;
@property(nonatomic, strong) GGDScanController *scanner;
@end

@implementation GGDOverlayRootView

- (instancetype)initWithFrame:(CGRect)frame scanner:(GGDScanController *)scanner {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;
    self.scanner = scanner;

    CGRect initial = CGRectMake(CGRectGetWidth(frame) - 104, 115, 90, 46);
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"GGDOverlayBubbleCenter"];
    if (saved.length) {
        CGPoint p = CGPointFromString(saved);
        if (p.x > 0 && p.y > 0) initial.origin.x = p.x - initial.size.width / 2.0;
        if (p.x > 0 && p.y > 0) initial.origin.y = p.y - initial.size.height / 2.0;
    }

    _bubble = [[GGDBubbleView alloc] initWithFrame:initial];
    __weak GGDOverlayRootView *weakSelf = self;
    _bubble.tapBlock = ^{
        __strong GGDOverlayRootView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.panel.hidden = !strongSelf.panel.hidden;
        [strongSelf setNeedsLayout];
    };
    _bubble.dragBlock = ^(CGPoint center) {
        __strong GGDOverlayRootView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf clampBubble];
        [[NSUserDefaults standardUserDefaults] setObject:NSStringFromCGPoint(strongSelf.bubble.center) forKey:@"GGDOverlayBubbleCenter"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [strongSelf setNeedsLayout];
    };
    [self addSubview:_bubble];

    _panel = [[GGDPanelView alloc] initWithFrame:CGRectMake(16, 170, 327, 462) scanner:scanner];
    _panel.hidden = YES;
    _panel.closeBlock = ^{
        __strong GGDOverlayRootView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.panel.hidden = YES;
        [strongSelf setNeedsLayout];
    };
    [self addSubview:_panel];
    return self;
}

- (void)clampBubble {
    CGFloat halfW = self.bubble.bounds.size.width / 2.0;
    CGFloat halfH = self.bubble.bounds.size.height / 2.0;
    CGFloat minX = 8 + halfW;
    CGFloat maxX = MAX(minX, self.bounds.size.width - 8 - halfW);
    CGFloat minY = 8 + halfH;
    CGFloat maxY = MAX(minY, self.bounds.size.height - 8 - halfH);
    CGFloat x = MIN(MAX(self.bubble.center.x, minX), maxX);
    CGFloat y = MIN(MAX(self.bubble.center.y, minY), maxY);
    self.bubble.center = CGPointMake(x, y);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [self clampBubble];

    if (self.panel.hidden) return;

    CGFloat width = MIN(343.0, MAX(300.0, self.bounds.size.width - 16.0));
    CGFloat height = MIN(470.0, MAX(390.0, self.bounds.size.height - 24.0));
    self.panel.frame = CGRectMake(0, 0, width, height);

    CGFloat x = self.bubble.center.x - width / 2.0;
    x = MIN(MAX(8.0, x), MAX(8.0, self.bounds.size.width - width - 8.0));

    CGFloat belowY = CGRectGetMaxY(self.bubble.frame) + 8.0;
    CGFloat y = belowY;
    if (y + height > self.bounds.size.height - 8.0) y = CGRectGetMinY(self.bubble.frame) - height - 8.0;
    if (y < 8.0) y = 8.0;
    self.panel.frame = CGRectMake(x, y, width, height);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (GGDPointInRect(point, self.bubble.frame)) return YES;
    if (!self.panel.hidden && GGDPointInRect(point, self.panel.frame)) return YES;
    return NO;
}

@end

static UIWindow *gOverlayWindow = nil;
static UIViewController *gOverlayController = nil;
static GGDOverlayRootView *gOverlayRoot = nil;
static GGDScanController *gOverlayScanner = nil;
static NSTimer *gOverlayWatchdog = nil;

static UIWindowScene *GGDFindActiveScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIScene *> *scenes = application.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
    }
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateUnattached) return windowScene;
    }
    return nil;
}

static void GGDCreateOverlayIfNeeded(void) {
    if (gOverlayWindow && gOverlayRoot) {
        if (gOverlayWindow.isHidden) gOverlayWindow.hidden = NO;
        return;
    }

    UIWindowScene *scene = GGDFindActiveScene();
    if (!scene) return;

    gOverlayScanner = [GGDScanController new];
    gOverlayController = [UIViewController new];
    gOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gOverlayWindow.frame = scene.coordinateSpace.bounds;
    gOverlayWindow.backgroundColor = UIColor.clearColor;
    gOverlayWindow.opaque = NO;
    gOverlayWindow.windowLevel = UIWindowLevelAlert;
    gOverlayWindow.hidden = NO;
    gOverlayWindow.userInteractionEnabled = YES;

    gOverlayRoot = [[GGDOverlayRootView alloc] initWithFrame:gOverlayWindow.bounds scanner:gOverlayScanner];
    gOverlayRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gOverlayController.view = gOverlayRoot;
    gOverlayController.view.backgroundColor = UIColor.clearColor;
    gOverlayWindow.rootViewController = gOverlayController;
    gOverlayWindow.hidden = NO;
}

static void GGDWatchdogTick(NSTimer *timer) {
    if (!gOverlayWindow || !gOverlayRoot) {
        GGDCreateOverlayIfNeeded();
        return;
    }
    UIWindowScene *scene = GGDFindActiveScene();
    if (scene && gOverlayWindow.windowScene != scene) {
        gOverlayWindow.hidden = YES;
        gOverlayWindow.windowScene = scene;
        gOverlayWindow.frame = scene.coordinateSpace.bounds;
        gOverlayWindow.hidden = NO;
        [gOverlayRoot setNeedsLayout];
    }
    if (gOverlayWindow.isHidden) gOverlayWindow.hidden = NO;
}

static void GGDStartOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ GGDStartOverlay(); });
        return;
    }
    GGDCreateOverlayIfNeeded();
    if (!gOverlayWatchdog) {
        gOverlayWatchdog = [NSTimer scheduledTimerWithTimeInterval:1.0 target:[NSBlockOperation blockOperationWithBlock:^{ GGDWatchdogTick(nil); }] selector:@selector(main) userInfo:nil repeats:YES];
    }
}

__attribute__((constructor))
static void GGDInit(void) {
    // No IL2CPP or game-object access here. UI is created asynchronously after a scene exists.
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attempts = 0;
        void (^retry)(void) = nil;
        retry = ^{
            attempts += 1;
            if (gOverlayWindow && gOverlayRoot) return;
            GGDCreateOverlayIfNeeded();
            if (!gOverlayWindow && attempts < 30) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
            }
        };
        retry();

        // Start the watchdog after the first scene has had time to settle.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GGDStartOverlay();
        });
    });
}
