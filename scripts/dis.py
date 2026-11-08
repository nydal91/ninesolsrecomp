"""dis.py <module> <guest addr> [count]: disassemble a module of the layout, with symbol names (dev tool)."""
import sys, os, subprocess, capstone
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'gen-out', 'tools'))
from nso import Nso
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
BASES = {}
for l in open(os.path.join(R, 'gen-out', 'layout.txt')):
    p = l.split()
    if len(p) >= 2 and not l.startswith('#'):
        try: BASES[p[0]] = int(p[1], 16)
        except ValueError: pass
mod, a = sys.argv[1], int(sys.argv[2], 16)
cnt = int(sys.argv[3]) if len(sys.argv) > 3 else 40
n = Nso(os.path.join(R, 'exefs', mod)); b = BASES[mod]
syms = sorted((v + b, s) for s, i, sh, v, sz in n.syms if sh)
import bisect
def sym(x):
    k = bisect.bisect_right([s[0] for s in syms], x) - 1
    if k < 0: return ''
    nm = subprocess.run(['c++filt', syms[k][1]], capture_output=True, text=True).stdout.strip()
    return f'{nm}+{x - syms[k][0]:#x}'
md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
off = a - b
for ins in md.disasm(bytes(n.image[off:off + cnt * 4]), a):
    extra = ''
    if ins.mnemonic in ('bl', 'b') and ins.op_str.startswith('#'):
        extra = '  ; ' + sym(int(ins.op_str[1:], 16))
    print(f'{ins.address:x}: {ins.mnemonic:8} {ins.op_str}{extra}')
