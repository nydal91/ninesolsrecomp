#!/usr/bin/env bash
# newgame.sh [ENV=val...]: boot with the control socket, Start Game -> slot 1 -> Standard Mode (a fresh save)
P=io.github.ninesolsrecomp; D=/storage/emulated/0/Android/data/$P/files
adb shell am force-stop $P; adb shell rm -f $D/savagewind.log
ex=(); for kv in "$@"; do ex+=(--es "${kv%%=*}" "${kv#*=}"); done
adb shell am start -n $P/com.deivid22srk.savagewind.MainActivity --es SAVAGEWIND_NO_LAUNCHER 1 --es SAVAGEWIND_CONTROL 7777 "${ex[@]}" >/dev/null
sleep 38  # (the title takes ~35 s to accept input)
"$(dirname "$0")"/ctl.sh press a 6 >/dev/null; sleep 4
"$(dirname "$0")"/ctl.sh press a 6 >/dev/null; sleep 4
"$(dirname "$0")"/ctl.sh press a 6 >/dev/null
