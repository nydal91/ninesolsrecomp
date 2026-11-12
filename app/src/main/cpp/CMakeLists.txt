# Savage Wind Recomp - Android port (arm64-v8a)
# Builds libmain.so: the original C runtime (runtime/, unchanged except for the Android platform
# layer and #ifdef'd process handling) + the Vulkan backend + ImGui + the JNI/TCC bridge.
# SDL3, FFmpeg, shaderc, Vulkan headers and VMA come prebuilt from scripts/build_deps_android.sh
# into deps/ (see the script; the CI workflow runs it before Gradle).
cmake_minimum_required(VERSION 3.22)
project(savagewind C CXX)

set(RUNTIME ${CMAKE_CURRENT_SOURCE_DIR}/runtime)
set(TOOLS ${CMAKE_CURRENT_SOURCE_DIR}/tools)
set(ANDROID_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android)
set(IMGUI ${CMAKE_CURRENT_SOURCE_DIR}/third_party/imgui)
set(STB ${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb)
set(SMAA ${CMAKE_CURRENT_SOURCE_DIR}/third_party/smaa)
set(DEPS ${CMAKE_CURRENT_SOURCE_DIR}/deps)
set(PY ${CMAKE_CURRENT_SOURCE_DIR}/../python)

include_directories(${RUNTIME} ${RUNTIME}/nvn ${STB} ${IMGUI} ${IMGUI}/backends ${DEPS}/include)
# (as the Makefile's -isystem third_party: the vendored vma/vk_mem_alloc.h)
include_directories(SYSTEM ${CMAKE_CURRENT_SOURCE_DIR}/third_party)

# ------------------------------------------------------------------ GAMELIB_ID
# The same hash runtime/gamebuild.c and the generated library share (the Makefile computes it
# from the generator sources, the headers they compile against, and the flags).
set(GAMELIB_ID_FILES
    ${PY}/gen.py ${PY}/lifter.py ${PY}/analyze.py ${PY}/nso.py
    ${PY}/passes.py ${PY}/patches.py ${PY}/simd_c.py
    ${TOOLS}/gamelib_entry.c
    ${RUNTIME}/hle/hle_symbols.txt
    ${RUNTIME}/cpu.h ${RUNTIME}/simd.h ${RUNTIME}/simd_fp.h ${RUNTIME}/simd_softfma.h ${RUNTIME}/gamelib.h
    ${PY}/layout.py ${PY}/game_sites.py)
set(GENFLAGS_ID "-O1 -fno-strict-aliasing -fvisibility=hidden -Iruntime")
set(GAMELIB_ID_INPUT "${CMAKE_BINARY_DIR}/gamelib_id_input")
file(WRITE "${GAMELIB_ID_INPUT}" "")
foreach(F ${GAMELIB_ID_FILES})
    file(READ "${F}" CONTENT)
    file(APPEND "${GAMELIB_ID_INPUT}" "${CONTENT}")
endforeach()
file(APPEND "${GAMELIB_ID_INPUT}" "${GENFLAGS_ID}\n")
file(SHA256 "${GAMELIB_ID_INPUT}" GAMELIB_ID_HASH)
string(SUBSTRING "${GAMELIB_ID_HASH}" 0 16 GAMELIB_ID)
message(STATUS "GAMELIB_ID: ${GAMELIB_ID}")
# The hash is taken when CMake configures: without this an edit to these files left the old id in place until
# something else made CMake configure again (the APKs up to 0.4.1-alpha.4-android.3 carried one from before the
# upstream sync, so a game code library made by older tools passed as current)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${GAMELIB_ID_FILES})

# ------------------------------------------------------------------ TRANSLATOR_ID / SPIRV_ID
# What translated shaders and their SPIR-V are made from, hashed as the Makefile does (the same ids as a desktop
# build of the same sources). The shader caches - cache/xlate, cache/spirv, the pipeline cache and list, the
# precompile - are kept while these stay the same. Without them translate.c and spirv.c fall back to their compile
# time, so every build that recompiled either one threw all those caches away on the player's phone.
set(TRANSLATOR_ID_INPUT "${CMAKE_BINARY_DIR}/translator_id_input")
file(READ "${RUNTIME}/nvn/maxwell/translate.c" CONTENT)
file(WRITE "${TRANSLATOR_ID_INPUT}" "${CONTENT}")
file(READ "${RUNTIME}/nvn/maxwell/shader.h" CONTENT)
file(APPEND "${TRANSLATOR_ID_INPUT}" "${CONTENT}")
file(SHA256 "${TRANSLATOR_ID_INPUT}" TRANSLATOR_ID_HASH)
string(SUBSTRING "${TRANSLATOR_ID_HASH}" 0 16 TRANSLATOR_ID)
file(SHA256 "${RUNTIME}/nvn/vulkan/spirv.c" SPIRV_ID_HASH)
string(SUBSTRING "${SPIRV_ID_HASH}" 0 16 SPIRV_ID)
# (configure again when they change: otherwise an incremental build kept the old ids and the phone its stale translations)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
             "${RUNTIME}/nvn/maxwell/translate.c" "${RUNTIME}/nvn/maxwell/shader.h" "${RUNTIME}/nvn/vulkan/spirv.c")
message(STATUS "TRANSLATOR_ID: ${TRANSLATOR_ID}, SPIRV_ID: ${SPIRV_ID}")
# (an edit to these files runs this again, so the ids follow)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${RUNTIME}/nvn/maxwell/translate.c" "${RUNTIME}/nvn/maxwell/shader.h" "${RUNTIME}/nvn/vulkan/spirv.c")

# ------------------------------------------------------------------ sources
file(GLOB RT_SRC CONFIGURE_DEPENDS ${RUNTIME}/*.c ${RUNTIME}/hle/*.c ${RUNTIME}/services/*.c
                 ${RUNTIME}/nvn/*.c ${RUNTIME}/nvn/maxwell/*.c)
file(GLOB VK_SRC ${RUNTIME}/nvn/vulkan/*.c ${RUNTIME}/nvn/vulkan/*.cpp)
file(GLOB UI_SRC ${RUNTIME}/ui/*.mm)
file(GLOB IMGUI_CORE ${IMGUI}/imgui.cpp ${IMGUI}/imgui_draw.cpp ${IMGUI}/imgui_tables.cpp
                     ${IMGUI}/imgui_widgets.cpp)
set(IMGUI_BACKENDS ${IMGUI}/backends/imgui_impl_sdl3.cpp ${IMGUI}/backends/imgui_impl_vulkan.cpp)

add_library(main SHARED
    ${RT_SRC} ${VK_SRC} ${UI_SRC}
    ${RUNTIME}/platform/android.c
    ${RUNTIME}/nvn/smaa_data.c
    ${RUNTIME}/nvn/vulkan/vma.cpp
    ${IMGUI_CORE} ${IMGUI_BACKENDS}
    ${ANDROID_DIR}/android_main.c ${ANDROID_DIR}/android_bridge.c
    ${ANDROID_DIR}/vk_dispatch.c)
# NOTE: tools/gamelib_entry.c is NOT part of libmain.so - it is the game code library's entry
# (compiled on the player's device into swgame.so, like the desktop Makefile's GEN_OBJ).

# the .mm UI sources are plain C++ apart from __APPLE__ blocks (as on Linux/Windows)
set_source_files_properties(${UI_SRC} PROPERTIES LANGUAGE CXX)

set_target_properties(main PROPERTIES
    OUTPUT_NAME "main"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")

target_compile_definitions(main PRIVATE
    GAMELIB_ID="${GAMELIB_ID}"
    VK_USE_PLATFORM_ANDROID_KHR)  # (AHardwareBuffer import: the guest heap, exec.c heap_pieces)
# gamebuild.c / gamelib.c carry the game-code build's flags (as the Makefile's -D does)
set_source_files_properties(${RUNTIME}/gamebuild.c ${RUNTIME}/gamelib.c PROPERTIES
    COMPILE_DEFINITIONS "GAMELIB_CFLAGS=\"-O1 -fno-strict-aliasing\";GAMELIB_SHARED=\"-shared\"")
# (only the two files that use them: a new id recompiles those, not the whole runtime)
set_source_files_properties(${RUNTIME}/nvn/maxwell/translate.c PROPERTIES COMPILE_DEFINITIONS "TRANSLATOR_ID=\"${TRANSLATOR_ID}\"")
set_source_files_properties(${RUNTIME}/nvn/vulkan/spirv.c PROPERTIES COMPILE_DEFINITIONS "SPIRV_ID=\"${SPIRV_ID}\"")

# the SMAA reference shader textures live next to the embedded shader string (as the Makefile's -I)
target_include_directories(main PRIVATE ${SMAA}/Textures)

# ------------------------------------------------------------------ flags
target_compile_options(main PRIVATE
    -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Wno-format
    -Wno-return-type -Wno-unused-label)

# ------------------------------------------------------------------ link
find_library(android-lib android)
find_library(log-lib log)
find_library(z-lib z)

# shaderc's static build is several archives (shaderc, shaderc_util, glslang, SPIRV-Tools...):
# a --start-group lets lld resolve them in any order.
file(GLOB SHADERC_ARCHIVES ${DEPS}/lib/shaderc/*.a)
list(SORT SHADERC_ARCHIVES)

target_link_libraries(main PRIVATE
    ${DEPS}/lib/libSDL3.so
    -Wl,--start-group
    ${DEPS}/lib/libavformat.a ${DEPS}/lib/libavcodec.a ${DEPS}/lib/libavutil.a
    ${DEPS}/lib/libswscale.a
    -Wl,--end-group
    ${SHADERC_ARCHIVES}
    adrenotools
    ${android-lib} ${log-lib} ${z-lib})

# SW_SOURCE: the source in the log's first line (runtime/main.c), as upstream's Makefile has it
execute_process(COMMAND git log -1 "--format=commit %h, tree %t" WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                OUTPUT_VARIABLE SW_SOURCE OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT SW_SOURCE)
    set(SW_SOURCE "unknown")
endif()
set_property(SOURCE ${RUNTIME}/main.c APPEND PROPERTY COMPILE_DEFINITIONS "SW_SOURCE=\"android, ${SW_SOURCE}\"")

# AMD FidelityFX SDK 1.1.4 (third_party/FidelityFX, MIT): FSR 3 frame interpolation, optical flow and the FSR 3
# upscaler on its Vulkan backend (runtime/nvn/vulkan/framegen.cpp, fsr3.cpp), as upstream's Makefile builds them; the
# shaders are prebuilt SPIR-V (third_party/FidelityFX/spirv).
set(FFX ${CMAKE_CURRENT_SOURCE_DIR}/third_party/FidelityFX)
file(GLOB FFX_SHARED ${FFX}/sdk/src/shared/*.cpp)
add_library(ffx STATIC
    ${FFX}/sdk/src/components/frameinterpolation/ffx_frameinterpolation.cpp
    ${FFX}/sdk/src/components/opticalflow/ffx_opticalflow.cpp
    ${FFX}/sdk/src/components/fsr3upscaler/ffx_fsr3upscaler.cpp
    ${FFX}/sdk/src/backends/vk/ffx_vk.cpp
    ${FFX_SHARED})
set(FFX_INC ${FFX}/sdk/include ${FFX}/sdk/src/components ${FFX}/sdk/src/shared ${FFX}/sdk/src/backends/shared)
target_include_directories(ffx BEFORE PRIVATE ${FFX_INC} ${FFX}/sdk/include/FidelityFX/gpu)
target_compile_options(ffx PRIVATE -w -include ${FFX}/ffx_compat.h)
set_target_properties(ffx PROPERTIES POSITION_INDEPENDENT_CODE ON)
string(REPLACE ";" " -I" FFX_INC_FLAGS "-I${FFX_INC}")
set_source_files_properties(${RUNTIME}/nvn/vulkan/fsr3.cpp PROPERTIES
    COMPILE_FLAGS "-DSW_FSR3=1 -include ${FFX}/ffx_compat.h ${FFX_INC_FLAGS}")
set_source_files_properties(${RUNTIME}/nvn/vulkan/framegen.cpp PROPERTIES
    COMPILE_FLAGS "-include ${FFX}/ffx_compat.h ${FFX_INC_FLAGS} -I${FFX}/spirv")
target_link_libraries(main PRIVATE ffx)

# Installed GPU drivers (Mesa Turnip...): libadrenotools loads them, android/vk_dispatch.c. Its hook libraries
# (libmain_hook.so...) are packaged too: adrenotools loads them from nativeLibraryDir.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/third_party/libadrenotools)
add_dependencies(main main_hook file_redirect_hook gsl_alloc_hook)

# The Android link runs with --no-undefined, which skips lld's __start_/__stop_ synthesis for the
# runtime's HLE / reset sections: hle.ld defines them (see the file).
target_link_options(main PRIVATE "-Wl,-T,${ANDROID_DIR}/hle.ld")

# ------------------------------------------------------------------ bootlog
# Startup crash diagnostics (see android/bootlog.c). MainActivity loads it first, so a native
# death while dlopen'ing SDL3 / libmain is recorded to the boot log + logcat "swboot" instead of
# dying silently (the system's fatal-signal report never reaches uid-filtered log captures).
add_library(bootlog SHARED ${ANDROID_DIR}/bootlog.c)
target_link_libraries(bootlog PRIVATE ${log-lib})
