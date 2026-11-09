# Nine Sols Recomp — Android

A static recompilation of the Nintendo Switch release of *Nine Sols* (Unity 2022.3.33f1, IL2CPP) to native
Android (arm64-v8a), built on the SavageWindRecomp / MvDK Recomp runtime: the game's ARM64 NSO modules are lifted
to C (`app/src/main/python/gen.py`), compiled into `swgame.so`, and run against an HLE Horizon kernel and services
with NVN translated to Vulkan.

> [!IMPORTANT]
> No game files are included. You need your own dump of Nine Sols (decrypted ExeFS + RomFS). Nothing is
> decrypted by this project.

## Status

Playable bring-up, tested on a Snapdragon 8 Gen 2 phone (Turnip v27): title, menus, new game, the opening movie,
gameplay in Peach Blossom Village, saving and loading, controller input and Wwise audio, all at 60 fps, with the
view widened to the phone's screen.

| Part | State |
|---|---|
| Lifting (gen.py) | main ~540k functions (C++ landing pads are function entries), 0 unsupported; sdk 1 (a CAS) |
| C++ exceptions | IL2CPP throws them for managed exceptions: per-frame setjmp records + HLE of libunwind's jumpto (`runtime/hle/unwind.c`) |
| Renderer | Unity's separate textures/samplers, VOTE.VTG, CSM flow tests done; image stores (SUST: PostProcessing's 3D LUT baker) missing |
| Wide screens | On by default (Video > Fill wide screens): the renderer draws the 16:9 targets at the screen's shape and Unity's `SetOrtho` / `SetPerspective` get a wider projection for 16:9 cameras (`runtime/hle/unity_wide.c`, gen.py `POST_HOOKS`), so more of the world shows instead of a stretch. The 16:9 UI stays centred; movies keep 16:9 with bars |
| Movies | Unity's VideoPlayer through `movie::` (FFmpeg VP8): the direct Extractor calls and Decoder slot 17 (GetOutputBuffer with its format) |
| Threads | Core tokens off by default (`SAVAGEWIND_CORES=1`): Unity's job workers stalled the boot about half the time with them |
| Audio | Wwise (Vorbis / PTADPCM, decoded in software) through `audout`; `hwopus` is only probed |
| Version check / RomFS check | Nine Sols main build id `0240741fc426c6c4`; Unity RomFS recognised by `Data/globalgamemanagers` + `global-metadata.dat` |
| Runtime, renderer, audio | Inherited from MvDK Recomp; Unity-specific gaps are found by booting |
| Touch | On-screen controller on by default on Android (stick, A B X Y, d-pad, L R ZL ZR, - +); it hides while a controller is used. Six fingers on the screen at once open the settings |
| Test helpers | `scripts/newgame.sh` (boot, Start Game, slot 1), `scripts/ctl.sh` (control socket on 7777: `press a 6`, `stick l 1 0 60`, `shot <name>`) |

## Building

```sh
python3 -m venv .venv && .venv/bin/pip install lz4 capstone unicorn
export JAVA_HOME=~/Android/jdk-17.0.13+11
./gradlew assembleRelease                      # the APK (native deps from scripts/build_deps_android.sh)
adb install -r app/build/outputs/apk/release/app-release.apk
scripts/build_gamelib_host.sh --push           # game code on this PC with the NDK, then exefs/romfs/swgame.so to the phone
```

Put your dump as `exefs/` and `romfs/` in the repository root (both are git-ignored). The on-device generator and
compiler from the original port still work, but `main` alone is ~1.5 GB of C: building it on the PC is far faster.

On the device the game files live in `/storage/emulated/0/Android/data/io.github.ninesolsrecomp/files/extracted/`;
the runtime log is `savagewind.log` one level up. To boot past the start screen (tests):
`adb shell am start -n io.github.ninesolsrecomp/com.deivid22srk.savagewind.MainActivity --es SAVAGEWIND_NO_LAUNCHER 1`.

## Bring-up log

1. Boots on an Adreno 740 (Android 15): Vulkan device, swapchain, start screen.
2. `swgame.so` loads; `sdk` and `subsdk0` initialisers run; `main`'s 354 static constructors start.
3. VAMM (npdm SystemResourceSize, GetInfo 16), a 16 GB alias region, MapPhysicalMemory that keeps mapped pages,
   LDXP/STXP, rtld symbol interposition, `nn::ro` lookup slot, SetThreadActivity / GetThreadContext3 (IL2CPP's GC
   stops the world with them), jump-table bases in code without an FDE.
4. C++ exceptions (`gen.py` eh_landing_pads / RtEhFrame in `cpu.h`), NVN: null pool flushes / program binds,
   nvnTextureGetMemoryPool, separate samplers; Maxwell: VOTE.VTG, flow tests 24-29, separate texture|sampler handles.
5. **Now:** title screen and menu at 60 fps. Open: compute SUST (3D LUT baking), an occasional black screen after
   loading (not reproduced on demand yet), ultrawide via Unity's camera.

## Credits

[SavageWindRecomp](https://github.com/Revivedx/SavageWindRecomp), [LAS Recomp](https://github.com/peiikai/LASRecomp)
(MIT) and the SavageWindRecomp-Android / MvDK Recomp ports. See LICENSE and the third-party notices of the
original project.
