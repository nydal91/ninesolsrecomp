#!/usr/bin/env bash
# bt.sh [log]: the last crash's host backtrace in a runtime log as guest functions with their symbols (dev tool)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG=${1:-$ROOT/.tmp/logs/savagewind.log}
NDK=$(ls -d "$HOME"/Android/Sdk/ndk/27.* | tail -1)/toolchains/llvm/prebuilt/linux-x86_64/bin
offs=$(awk '/^host backtrace/{f=1; s=""} f&&/\(swgame.so\)/{match($0,/\+[0-9a-f]+ \(swgame/); s=s" 0x"substr($0,RSTART+1,RLENGTH-9)} END{print s}' "$LOG")
lr=$(grep -o 'lr=[0-9a-f]*' "$LOG" | tail -1 | cut -d= -f2)
fns=$(for o in $offs; do "$NDK"/llvm-symbolizer --obj="$ROOT/gen-out/swgame.so" "$o" | head -1 | sed 's/^f_//'; done)
"$ROOT/.venv/bin/python" "$ROOT/scripts/sym.py" $fns ${lr:+$lr} 2>/dev/null
