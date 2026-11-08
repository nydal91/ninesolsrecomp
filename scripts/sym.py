"""sym.py <guest addr>...: the module and symbol at guest addresses (dev tool)."""
import sys, os, subprocess, bisect
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(R, 'gen-out', 'tools'))
from nso import Nso
mods = []
for l in open(os.path.join(R, 'gen-out', 'layout.txt')):
    p = l.split()
    if len(p) >= 3 and not l.startswith('#'):
        n = Nso(os.path.join(R, 'exefs', p[0])); b = int(p[1], 16)
        syms = sorted((v + b, s) for s, i, sh, v, sz in n.syms if sh)
        mods.append((p[0], b, int(p[2], 16), syms))
for a in (int(x, 16) for x in sys.argv[1:]):
    for name, b, size, syms in mods:
        if b <= a < b + size:
            k = bisect.bisect_right([s[0] for s in syms], a) - 1
            nm = subprocess.run(['c++filt', syms[k][1]], capture_output=True, text=True).stdout.strip() if k >= 0 else '?'
            print(f'{a:x} {name} {nm[:150]} +{a - syms[k][0]:#x}' if k >= 0 else f'{a:x} {name} ?')
            break
    else:
        print(f'{a:x} (not in a module)')
