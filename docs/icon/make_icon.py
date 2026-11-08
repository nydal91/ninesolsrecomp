# Nine Sols Recomp's app icon (original art): nine suns - one great one with a halo, eight small ones on an arc -
# over layered mountains, on a rounded dark-teal square. Writes docs/icon/icon.png and the Android mipmaps.
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
root = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(os.path.dirname(root))

def lerp(a, b, f): return tuple(int(a[i] + (b[i] - a[i]) * f) for i in range(len(a)))

img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
# background: a vertical gradient, teal-black to crimson dusk
bg = Image.new('RGBA', (S, S))
d = ImageDraw.Draw(bg)
for y in range(S):
    f = y / S
    c = lerp((8, 18, 32), (24, 34, 56), f / 0.55) if f < 0.55 else lerp((24, 34, 56), (130, 36, 52), (f - 0.55) / 0.45)
    d.line([(0, y), (S, y)], fill=c + (255,))
sun = (512, 430)
# glow behind the sun
glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse([sun[0] - 330, sun[1] - 330, sun[0] + 330, sun[1] + 330], fill=(255, 150, 70, 120))
glow = glow.filter(ImageFilter.GaussianBlur(110))
bg = Image.alpha_composite(bg, glow)
d = ImageDraw.Draw(bg)
R = 150
for i, (r, w, a) in enumerate(((R * 1.45, 10, 170), (R * 1.75, 6, 110))):
    d.ellipse([sun[0] - r, sun[1] - r, sun[0] + r, sun[1] + r], outline=(255, 216, 138, a), width=w)
for i in range(12):
    a = i * math.tau / 12
    p0 = (sun[0] + math.cos(a) * R * 1.28, sun[1] + math.sin(a) * R * 1.28)
    p1 = (sun[0] + math.cos(a) * R * 1.40, sun[1] + math.sin(a) * R * 1.40)
    d.line([p0, p1], fill=(255, 216, 138, 200), width=8)
d.ellipse([sun[0] - R, sun[1] - R, sun[0] + R, sun[1] + R], fill=(255, 230, 168, 255))
d.ellipse([sun[0] - R * 0.8, sun[1] - R * 0.8, sun[0] + R * 0.8, sun[1] + R * 0.8], fill=(255, 245, 215, 255))
# eight small suns on an arc over the top
small = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(small)
pts = []
for i in range(8):
    a = math.pi * (1.0 + i / 7.0)
    pts.append((sun[0] + math.cos(a) * 395, sun[1] + 70 + math.sin(a) * 345))
for x, y in pts: sd.ellipse([x - 52, y - 52, x + 52, y + 52], fill=(255, 150, 70, 150))
small = small.filter(ImageFilter.GaussianBlur(22))
bg = Image.alpha_composite(bg, small)
d = ImageDraw.Draw(bg)
for x, y in pts: d.ellipse([x - 27, y - 27, x + 27, y + 27], fill=(255, 226, 160, 255))
# mountains, two layers, and a pagoda on the near peak
def ridge(seed, base, amp, col):
    poly = [(0, S)]
    for x in range(0, S + 8, 8):
        u = x / S
        v = sum(math.sin(u * (1.3 + k * 2.1) * math.tau + seed * (k + 1)) / (1 + k * 1.5) for k in range(3))
        poly.append((x, base - amp * (0.5 + 0.3 * v)))
    poly.append((S, S))
    d.polygon(poly, fill=col)
ridge(1.7, 800, 220, (38, 54, 78, 255))
ridge(4.1, 900, 170, (16, 28, 42, 255))
ridge(2.6, 1000, 120, (6, 12, 20, 255))
cx, y = 300, 812
for tier in range(3):
    w, h = 120 * (1 - tier * 0.22), 58 - tier * 8
    d.rectangle([cx - w / 2, y - h, cx + w / 2, y], fill=(6, 12, 20, 255))
    y -= h
    rw, rh = w * 0.95, 26
    d.polygon([(cx - rw, y - rh * 0.4), (cx - rw * 0.7, y), (cx + rw * 0.7, y), (cx + rw, y - rh * 0.4),
               (cx + rw * 0.55, y - rh), (cx - rw * 0.55, y - rh)], fill=(6, 12, 20, 255))
    y -= rh
d.line([(cx, y), (cx, y - 45)], fill=(6, 12, 20, 255), width=6)
d.ellipse([cx - 9, y - 58, cx + 9, y - 40], fill=(255, 90, 70, 255))
# a cyan circuit trace across the foreground
c = (58, 224, 208, 255)
trace = [(560, 1024), (560, 930), (700, 930), (700, 880), (820, 880)]
d.line(trace, fill=c, width=9, joint='curve')
for p in (trace[1], trace[3], trace[4]): d.ellipse([p[0] - 14, p[1] - 14, p[0] + 14, p[1] + 14], fill=c)
# rounded square mask
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=200, fill=255)
img.paste(bg, (0, 0), mask)
img.save(os.path.join(root, 'icon.png'))
for name, px in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    img.resize((px, px), Image.LANCZOS).save(os.path.join(repo, 'app/src/main/res/mipmap-%s/ic_launcher.png' % name))
print('ok')
