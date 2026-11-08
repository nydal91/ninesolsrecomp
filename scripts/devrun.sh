#!/usr/bin/env bash
# devrun.sh [seconds] [ENV=value ...]: start the game on the phone past the start screen, wait, screenshot, stop the
# app (always), and copy the runtime log to .tmp/logs/savagewind.log (dev loop; adb with the phone attached).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=io.github.ninesolsrecomp
D=/storage/emulated/0/Android/data/$P/files
WAIT=${1:-45}; shift || true
EXTRA=(--es SAVAGEWIND_NO_LAUNCHER 1)
for kv in "$@"; do EXTRA+=(--es "${kv%%=*}" "${kv#*=}"); done
mkdir -p "$ROOT/.tmp/logs"
rm -f "$ROOT/.tmp/logs/savagewind.log" "$ROOT/.tmp/logs/screen.png"
adb shell am force-stop $P
adb shell input keyevent KEYCODE_WAKEUP
adb shell rm -f $D/savagewind.log
adb shell am start -n $P/com.deivid22srk.savagewind.MainActivity "${EXTRA[@]}" >/dev/null
sleep "$WAIT"
adb exec-out screencap -p > "$ROOT/.tmp/logs/screen.png"
adb shell pidof $P >/dev/null && echo "[devrun] still running after ${WAIT}s" || echo "[devrun] process gone"
adb shell am force-stop $P
adb pull $D/savagewind.log "$ROOT/.tmp/logs/" >/dev/null 2>&1 || echo "[devrun] no savagewind.log (died before it was opened?)"
