// The Vulkan library, chosen at startup: the phone's own driver (the system libvulkan.so) or one the player installed
// (Mesa Turnip and other Adreno drivers in the AdrenoTools format: a zip with meta.json and the driver's .so),
// loaded through libadrenotools (third_party/libadrenotools), which opens the system loader in a linker namespace of
// its own with the driver swapped in.
//
// libmain.so doesn't link libvulkan: every Vulkan command the runtime, VMA and ImGui call is defined here
// (vk_dispatch_gen.inc, made by gen_vk_dispatch.py from deps/include/vulkan) and calls through a table filled from
// the chosen library's vkGetInstanceProcAddr / vkGetDeviceProcAddr. (That also gives the Vulkan 1.2 / 1.3 commands
// Android's loader doesn't export - this replaced vulkan_shims.c.)
//
// Drivers: MainActivity unpacks each zip in <external files>/drivers into <files>/drivers/<name>/ (native code can't
// load from shared storage) and passes that folder in SAVAGEWIND_DRIVERS_DIR. The setting gpu_driver (Video > GPU
// driver; savagewind.ini) names the folder, empty = the system driver; SAVAGEWIND_GPU_DRIVER=<name>|system overrides
// it. A driver that fails to load or shows no GPU falls back to the system one.
//
// Also here: GPU max clocks (setting gpu_turbo). KGSL's power control property - any app may set it - holds the GPU at
// its top clock, within thermal limits. The phone's governor clocks by load, and a frame that is a chain (the game
// waits for the GPU, the translated command lists reach it in pieces) never looks busy: an Adreno 740 sat at 300-400
// of its 680 MHz and the Shrine ran 14.7 fps; held at the top, 19.
#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <vulkan/vulkan.h>
#include <adrenotools/driver.h>

#include "vk_dispatch.h"

#include "vk_dispatch_gen.inc"

#define VLOG(...) fprintf(stderr, __VA_ARGS__)  // (as rt.h LOG: the game log)

static void *lib;
static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
static char driver_name[96] = "system";
static bool custom;

static bool read_meta(const char *dir, char *so, size_t n, char *name, size_t nn) {
    char p[512];
    snprintf(p, sizeof p, "%s/meta.json", dir);
    FILE *f = fopen(p, "r");
    if (!f) return false;
    char buf[4096];
    size_t len = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[len] = 0;
    so[0] = name[0] = 0;
    const char *keys[2] = {"\"libraryName\"", "\"name\""};
    char *outs[2] = {so, name};
    size_t ns[2] = {n, nn};
    for (int k = 0; k < 2; k++) {
        const char *s = strstr(buf, keys[k]);
        if (!s) continue;
        s = strchr(s + strlen(keys[k]), '"');
        if (!s) continue;
        const char *e = strchr(++s, '"');
        if (!e) continue;
        snprintf(outs[k], ns[k], "%.*s", (int)(e - s), s);
    }
    return so[0] != 0;
}

static bool open_system(void) {
    lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    custom = false;
    snprintf(driver_name, sizeof driver_name, "system");
    return lib != NULL;
}

static bool open_custom(const char *want) {
    const char *dir = getenv("SAVAGEWIND_DRIVERS_DIR"), *hooks = getenv("SAVAGEWIND_LIB_DIR");
    if (!dir || !hooks) return false;
    char path[512], so[128], name[96];
    snprintf(path, sizeof path, "%s/%s", dir, want);
    if (!read_meta(path, so, sizeof so, name, sizeof name)) {
        VLOG("[vk] GPU driver '%s': no meta.json with a libraryName in %s\n", want, path);
        return false;
    }
    strcat(path, "/");  // (adrenotools joins the folder and the name as they are)
    void *h = adrenotools_open_libvulkan(RTLD_NOW | RTLD_LOCAL, ADRENOTOOLS_DRIVER_CUSTOM, NULL, hooks, path, so, NULL, NULL);
    if (!h) {
        VLOG("[vk] GPU driver '%s' (%s%s): adrenotools could not load it\n", want, path, so);
        return false;
    }
    lib = h;
    custom = true;
    snprintf(driver_name, sizeof driver_name, "%s", name[0] ? name : want);
    return true;
}

// (every Vulkan command reaches the library through here first)
static void load_global(void) {
    if (gipa) return;
    extern const char *settings_gpu_driver(void);
    const char *want = getenv("SAVAGEWIND_GPU_DRIVER");
    if (!want || !*want) want = settings_gpu_driver();
    bool ok = want && *want && strcmp(want, "system") && open_custom(want);
    if (!ok && !open_system()) {
        VLOG("[vk] libvulkan.so: %s\n", dlerror());
        abort();
    }
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    for (int i = 0; i < VKD_COUNT; i++) vkd_fn[i] = gipa(NULL, vkd_names[i]);
    VLOG("[vk] Vulkan driver: %s\n", driver_name);
}

static void fall_back(void) {  // (the custom driver didn't work out: the system one, for good)
    VLOG("[vk] GPU driver %s failed: the system driver instead\n", driver_name);
    gipa = NULL;
    gdpa = NULL;
    lib = NULL;  // (left loaded: unloading a driver isn't safe)
    if (!open_system()) abort();
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    for (int i = 0; i < VKD_COUNT; i++) vkd_fn[i] = gipa(NULL, vkd_names[i]);
}

// The GPU the driver in use shows can't run the game (no Vulkan 1.3: runtime/nvn/vulkan/device.c pick_device): another
// installed driver instead, once the runtime has destroyed its instance. False (and the system driver) when it could
// not be loaded.
bool vk_driver_switch(const char *want) {
    gipa = NULL;
    gdpa = NULL;
    lib = NULL;  // (left loaded: unloading a driver isn't safe)
    bool ok = open_custom(want);
    if (!ok && !open_system()) abort();
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    for (int i = 0; i < VKD_COUNT; i++) vkd_fn[i] = gipa(NULL, vkd_names[i]);
    VLOG("[vk] Vulkan driver: %s\n", driver_name);
    return ok;
}

const char *vk_driver_name(void) { return driver_name; }
bool vk_driver_custom(void) { return custom; }

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance inst, const char *name) {
    load_global();
    return gipa(inst, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d, const char *name) {
    load_global();
    if (!gdpa) gdpa = (PFN_vkGetDeviceProcAddr)vkd_fn[VKD_vkGetDeviceProcAddr];
    return gdpa(d, name);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceVersion(uint32_t *v) {
    load_global();
    PFN_vkEnumerateInstanceVersion f = (PFN_vkEnumerateInstanceVersion)vkd_fn[VKD_vkEnumerateInstanceVersion];
    if (!f) { *v = VK_API_VERSION_1_0; return VK_SUCCESS; }
    return f(v);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *n, VkExtensionProperties *p) {
    load_global();
    return ((PFN_vkEnumerateInstanceExtensionProperties)vkd_fn[VKD_vkEnumerateInstanceExtensionProperties])(layer, n, p);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t *n, VkLayerProperties *p) {
    load_global();
    return ((PFN_vkEnumerateInstanceLayerProperties)vkd_fn[VKD_vkEnumerateInstanceLayerProperties])(n, p);
}

static void load_instance(VkInstance inst) {
    for (int i = 0; i < VKD_COUNT; i++) {
        PFN_vkVoidFunction f = gipa(inst, vkd_names[i]);
        if (f) vkd_fn[i] = f;
    }
    gdpa = (PFN_vkGetDeviceProcAddr)vkd_fn[VKD_vkGetDeviceProcAddr];
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *ac, VkInstance *out) {
    load_global();
    VkResult r = ((PFN_vkCreateInstance)vkd_fn[VKD_vkCreateInstance])(ci, ac, out);
    if (r == VK_SUCCESS && custom) {  // (adrenotools' hook failing shows as an instance without GPUs)
        PFN_vkEnumeratePhysicalDevices en = (PFN_vkEnumeratePhysicalDevices)gipa(*out, "vkEnumeratePhysicalDevices");
        uint32_t n = 0;
        if (!en || en(*out, &n, NULL) != VK_SUCCESS || !n) {
            ((PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance"))(*out, ac);
            r = VK_ERROR_INITIALIZATION_FAILED;
        }
    }
    if (r != VK_SUCCESS && custom) {
        VLOG("[vk] vkCreateInstance with %s: %d\n", driver_name, r);
        fall_back();
        r = ((PFN_vkCreateInstance)vkd_fn[VKD_vkCreateInstance])(ci, ac, out);
    }
    if (r == VK_SUCCESS) load_instance(*out);
    return r;
}

// The runtime makes one device: its commands come straight from the driver (no loader trampoline).
VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *ac, VkDevice *out) {
    VkResult r = ((PFN_vkCreateDevice)vkd_fn[VKD_vkCreateDevice])(pd, ci, ac, out);
    if (r != VK_SUCCESS) return r;
    for (int i = 0; i < VKD_COUNT; i++) {
        PFN_vkVoidFunction f = gdpa(*out, vkd_names[i]);
        if (f) vkd_fn[i] = f;
    }
    return r;
}

// ------------------------------------------------------------------ GPU max clocks
// (struct and numbers: the kernel's msm_kgsl.h, as libadrenotools' adrenotools_set_turbo has them; kept here so
// turning it off again needs no other copy)
struct kgsl_prop { unsigned int type; void *value; size_t sizebytes; };
#define KGSL_PROP_PWRCTRL 0xE
#define IOCTL_KGSL_SETPROPERTY _IOW(0x09, 0x32, struct kgsl_prop)

static int turbo_state = -1;
void vk_gpu_turbo(bool on) {
    if (getenv("SAVAGEWIND_NO_GPU_TURBO")) on = false;
    if (turbo_state == (int)on) return;
    uint32_t enable = on ? 0u : 1u;  // (the property is "power control enabled": 0 = held at the top)
    struct kgsl_prop p = {KGSL_PROP_PWRCTRL, &enable, sizeof enable};
    int fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) return;
    int r = ioctl(fd, IOCTL_KGSL_SETPROPERTY, &p);
    close(fd);
    if (turbo_state < 0 || r) VLOG("[vk] GPU max clocks %s%s\n", on ? "on" : "off", r ? " (refused)" : "");
    if (!r) turbo_state = on;
}
