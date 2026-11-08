#!/usr/bin/env bash
# Build the game code library (swgame.so) for Android on this PC, instead of on the phone.
#
# The app normally runs tools/gen.py and its bundled clang on the device (runtime/gamebuild.c). For Nine Sols the
# main module is 81 MB of ARM64 code -> ~1.5 GB of C, which takes hours on a phone. This does the same steps with
# the NDK's clang here, with the same flags and the same GAMELIB_ID the APK checks, so the library is accepted as is.
#
#   scripts/build_gamelib_host.sh [exefs] [outdir]        generate + compile + link  -> <outdir>/swgame.so(.id)
#   scripts/build_gamelib_host.sh --push                   also push exefs/, romfs/, swgame.so to the device
#
# Needs: the APK built once (app/build: libmain.so, GAMELIB_ID), the NDK, and a Python with lz4, capstone, unicorn
# (PYTHON=..., default .venv/bin/python).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PUSH=0
ARGS=()
for a in "$@"; do [ "$a" = --push ] && PUSH=1 || ARGS+=("$a"); done
EXEFS=$(realpath "${ARGS[0]:-$ROOT/exefs}")
OUT=$(realpath -m "${ARGS[1]:-$ROOT/gen-out}")
PY=${PYTHON:-$ROOT/.venv/bin/python}
NDK=${ANDROID_NDK:-$(ls -d "$HOME"/Android/Sdk/ndk/27.* | tail -1)}
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang --target=aarch64-linux-android28"
JOBS=${JOBS:-$(nproc)}
PKG=io.github.ninesolsrecomp
SRC=$ROOT/app/src/main
RT=$SRC/cpp/runtime

# the id the APK expects (app/src/main/cpp/CMakeLists.txt computes it the same way at configure time)
IDIN=$(ls "$ROOT"/app/.cxx/Release/*/arm64-v8a/gamelib_id_input 2>/dev/null | head -1)
[ -n "$IDIN" ] || { echo "build the APK first (./gradlew assembleRelease): no gamelib_id_input"; exit 1; }
ID=$(sha256sum "$IDIN" | cut -c1-16)
LIBMAIN=$(ls "$ROOT"/app/build/intermediates/cxx/Release/*/obj/arm64-v8a/libmain.so | head -1)
echo "GAMELIB_ID $ID, libmain $LIBMAIN, $JOBS jobs"

# 1. generate (the device's flags: --simd asm on arm64; --hle for every module but main)
mkdir -p "$OUT"
# (the .py files alone: app/src/main/python also holds the Android builds of capstone / unicorn, which would shadow
# this Python's own)
mkdir -p "$OUT/tools" && cp "$SRC"/python/*.py "$OUT/tools/"
( cd "$OUT/tools" && "$PY" gen.py all "$EXEFS" "$OUT" --hle "$RT/hle/hle_symbols.txt" --simd asm 2>&1 \
    | grep -v ': progress' )

# 2. compile (only what changed: gen.py rewrites a chunk only when its text changes)
CFLAGS="-O1 -fno-strict-aliasing -fvisibility=hidden -fPIC -I$RT -DGAMELIB_ID=\"$ID\" -w"
export CC CFLAGS
mkdir -p "$OUT/obj"
# (objects built against other headers or flags: start over. The id itself is only compiled into gamelib_entry.o,
# so a new id from a generator change alone rebuilds just that one: the chunks gen.py rewrote are newer than theirs)
HDR=$(cat "$RT"/cpu.h "$RT"/simd*.h "$RT"/gamelib.h <(echo "$CC $CFLAGS" | sed 's/-DGAMELIB_ID=[^ ]*//') | sha256sum | cut -c1-16)
[ "$(cat "$OUT/obj/.hdr" 2>/dev/null)" = "$HDR" ] || { rm -f "$OUT"/obj/*.o; echo "$HDR" > "$OUT/obj/.hdr"; }
[ "$(cat "$OUT/obj/.id" 2>/dev/null)" = "$ID" ] || { rm -f "$OUT/obj/gamelib_entry.o"; echo "$ID" > "$OUT/obj/.id"; }
compile() {  # <src> <obj>
    [ "$2" -nt "$1" ] && exit 0
    $CC $CFLAGS -c "$1" -o "$2.tmp" && mv "$2.tmp" "$2" || { echo "FAILED: $1"; exit 1; }
}
export -f compile
{
    echo "$SRC/cpp/tools/gamelib_entry.c $OUT/obj/gamelib_entry.o"
    echo "$OUT/layout.c $OUT/obj/layout.o"
    for m in "$OUT"/*/; do
        n=$(basename "$m"); case $n in obj | tools) continue ;; esac
        for c in "$m"*.c; do echo "$c $OUT/obj/${n}__$(basename "${c%.c}").o"; done
    done
} > "$OUT/units.txt"
N=$(wc -l < "$OUT/units.txt")
echo "compiling $N files"
# (big chunks first: they take longest)
xargs -a "$OUT/units.txt" -P "$JOBS" -n 2 bash -c 'compile "$0" "$1"'

# 3. link against libmain.so (the runtime functions the game code calls)
cut -d' ' -f2 "$OUT/units.txt" > "$OUT/link.rsp"
$CC -shared -o "$OUT/swgame.so.tmp" @"$OUT/link.rsp" -L"$(dirname "$LIBMAIN")" -lmain -lm -Wl,--no-undefined \
    -Wl,-z,max-page-size=16384
mv "$OUT/swgame.so.tmp" "$OUT/swgame.so"
echo "$ID" > "$OUT/swgame.so.id"
ls -la "$OUT/swgame.so"

# 4. (--push) the app's data folder on the device: exefs/, romfs/, the library
if [ $PUSH = 1 ]; then
    D=/storage/emulated/0/Android/data/$PKG/files/extracted  # (the game root: runtime/main.c)
    adb shell mkdir -p "$D"
    adb push --sync "$EXEFS" "$D/"
    [ -d "$ROOT/romfs" ] && adb push --sync "$ROOT/romfs" "$D/"
    adb push "$OUT/swgame.so" "$OUT/swgame.so.id" "$D/"
    # (pushed files belong to the shell user, mode rwxrws---: the app, reading Android/data/<pkg> straight from the
    # lower file system, isn't in their group - "the game code hasn't been built")
    adb shell chmod -R o+rwX "$D"
fi
