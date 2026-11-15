// android/vk_dispatch.c: the Vulkan library in use and GPU max clocks
#pragma once
#include <stdbool.h>
const char *vk_driver_name(void);  // "system", or the installed driver's name (its meta.json)
bool vk_driver_custom(void);
bool vk_driver_switch(const char *name);  // another installed driver, after the instance is gone (false: not loaded)
void vk_gpu_turbo(bool on);        // hold the GPU at its top clock (KGSL power control), or let it go

// android/android_bridge.c: Video > GPU driver > Install driver from .zip (the system file picker, MainActivity)
#include <stddef.h>
bool android_pick_driver_zip(void);
bool android_driver_install_poll(char *name, size_t name_cap, char *error, size_t error_cap);

// No Vulkan 1.3 GPU (runtime/nvn/vulkan/device.c): asks the player for a driver before anything is drawn
// (MainActivity.chooseDriver), the answer through android_driver_install_poll. False: no dialog could be shown.
bool android_choose_driver(const char *message);
