#!/usr/bin/env bash
# ctl.sh <command...>: send one control command to the running game (SAVAGEWIND_CONTROL=7777, adb forward) and
# print the reply. ctl.sh shot <name>: screenshot to .tmp/logs/<name>.png.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "$1" = shot ]; then adb exec-out screencap -p > "$ROOT/.tmp/logs/$2.png"; exit; fi
adb forward tcp:7777 tcp:7777 >/dev/null
python3 - "$@" <<'PY'
import socket, sys
s = socket.create_connection(('127.0.0.1', 7777), timeout=5)
s.sendall((' '.join(sys.argv[1:]) + '\n').encode())
try: print(s.recv(65536).decode().strip()[:400])
except Exception as e: print('no reply', e)
PY
