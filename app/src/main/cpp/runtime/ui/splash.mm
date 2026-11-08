// The start screen's background (splash.h). The player's own picture when there is one (rt_user_splash: splash.jpg /
// splash.png in the data folder, decoded with stb_image), shown filling the window; else MvDK Recomp's own art
// (girder_art: a building site at sunset). Savage Wind's forest art is kept below (forest_art): an old forest at a sunlit clearing, the icon's plain sword (docs/icon/icon.svg) in a mossy stone, the grass
// swaying, petals and fireflies. The menu sits on the left, so the clearing is on the right. The start screen lays its
// dark banners over either, which keep its text readable.
#ifdef __APPLE__
#import <Metal/Metal.h>
#endif
#include <algorithm>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"  // (ImDrawListSharedData: the white pixel's UV for hand-made geometry)
#include "splash.h"

#include "imageload.h"  // (stb_image, JPEG / PNG: SDL 3.2, which the distributions ship, has no SDL_LoadPNG)

extern "C" {
#include "paths.h"
#ifdef __APPLE__
void *ui_metal_device(void);
#else
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);  // runtime/nvn/vulkan/imgui_glue.cpp
void vk_imgui_texture_free(uint64_t tex);
#endif
}

// ------------------------------------------------------------------ the player's picture
static ImTextureID g_tex;
static int g_tex_w, g_tex_h;
#ifdef __APPLE__
static id<MTLTexture> g_mtl_tex;  // (ImGui only holds the pointer)
#endif

void splash_load(void) {
    splash_unload();
    char path[1100];
    if (!rt_user_splash(path, sizeof path)) return;
    int w, h;
    if (!rt_image_info(path, &w, &h) || w <= 0 || h <= 0 || w > 8192 || h > 8192) {
        fprintf(stderr, "[splash] %s: not a JPEG / PNG up to 8192x8192, using the default art\n", path);
        return;
    }
    unsigned char *px = rt_image_rgba(path, &w, &h);
    if (!px) {
        fprintf(stderr, "[splash] %s: %s, using the default art\n", path, rt_image_error());
        return;
    }
#ifdef __APPLE__
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:w height:h mipmapped:NO];
    g_mtl_tex = [dev newTextureWithDescriptor:td];
    if (g_mtl_tex) {
        [g_mtl_tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:(NSUInteger)w * 4];
        g_tex = (ImTextureID)(intptr_t)(__bridge void *)g_mtl_tex;
    }
#else
    g_tex = (ImTextureID)vk_imgui_texture_rgba(px, w, h);
#endif
    rt_image_free(px);
    if (g_tex) g_tex_w = w, g_tex_h = h;
    fprintf(stderr, "[splash] %s (%dx%d)%s\n", path, w, h, g_tex ? "" : ": no texture, using the default art");
}

void splash_unload(void) {
    if (!g_tex) return;
#ifdef __APPLE__
    g_mtl_tex = nil;
#else
    vk_imgui_texture_free((uint64_t)g_tex);
#endif
    g_tex = 0;
}

bool splash_is_user(void) { return g_tex != 0; }

// ------------------------------------------------------------------ drawing helpers
static ImU32 rgba(uint32_t rgb, float a = 1) {
    return IM_COL32(rgb >> 16 & 255, rgb >> 8 & 255, rgb & 255, (int)(a * 255 + 0.5f));
}

// A filled (concave) polygon shaded from ca at a to cb at b (a linear gradient). ImGui anti-aliases clockwise
// outlines (on screen, y down) outwards: counter-clockwise ones are turned around first.
static void fill_grad(ImDrawList *dl, const ImVec2 *p, int n, ImVec2 a, ImVec2 b, ImU32 ca, ImU32 cb) {
    float area = 0;
    for (int i = 0; i < n; i++) area += p[i].x * p[(i + 1) % n].y - p[(i + 1) % n].x * p[i].y;
    std::vector<ImVec2> rev;
    if (area < 0) rev.assign(p, p + n), std::reverse(rev.begin(), rev.end()), p = rev.data();
    int v0 = dl->VtxBuffer.Size;
    dl->AddConcavePolyFilled(p, n, IM_COL32_WHITE);
    ImVec2 d(b.x - a.x, b.y - a.y);
    float dd = d.x * d.x + d.y * d.y;
    ImVec4 A = ImGui::ColorConvertU32ToFloat4(ca), B = ImGui::ColorConvertU32ToFloat4(cb);
    for (int i = v0; i < dl->VtxBuffer.Size; i++) {
        ImDrawVert &v = dl->VtxBuffer[i];
        float f = dd > 0 ? ((v.pos.x - a.x) * d.x + (v.pos.y - a.y) * d.y) / dd : 0;
        f = f < 0 ? 0 : f > 1 ? 1 : f;
        float fringe = (float)(v.col >> IM_COL32_A_SHIFT & 255) / 255.0f;  // (0 on the anti-aliased edge)
        v.col = ImGui::ColorConvertFloat4ToU32(ImVec4(A.x + (B.x - A.x) * f, A.y + (B.y - A.y) * f,
                                                      A.z + (B.z - A.z) * f, (A.w + (B.w - A.w) * f) * fringe));
    }
}

static void fill(ImDrawList *dl, const ImVec2 *p, int n, ImU32 c) { fill_grad(dl, p, n, p[0], p[0], c, c); }

// A soft round glow: inner at the centre, mid at mid_at of the radius, nothing at the edge
static void glow(ImDrawList *dl, ImVec2 c, float r, ImU32 inner, ImU32 mid, float mid_at) {
    const int N = 72;
    ImU32 out = mid & ~IM_COL32_A_MASK;
    ImVec2 uv = dl->_Data->TexUvWhitePixel;
    dl->PrimReserve(N * 3 + N * 6, 1 + 2 * N);
    unsigned base = dl->_VtxCurrentIdx;
    dl->PrimWriteVtx(c, uv, inner);
    for (int ring = 0; ring < 2; ring++)
        for (int i = 0; i < N; i++) {
            float a = i * 6.2831853f / N, rr = ring ? r : r * mid_at;
            dl->PrimWriteVtx(ImVec2(c.x + cosf(a) * rr, c.y + sinf(a) * rr), uv, ring ? out : mid);
        }
    for (int i = 0; i < N; i++) {
        unsigned j = (i + 1) % N, a = base + 1 + i, b = base + 1 + j, a2 = a + N, b2 = b + N;
        dl->PrimWriteIdx((ImDrawIdx)base), dl->PrimWriteIdx((ImDrawIdx)a), dl->PrimWriteIdx((ImDrawIdx)b);
        dl->PrimWriteIdx((ImDrawIdx)a), dl->PrimWriteIdx((ImDrawIdx)b2), dl->PrimWriteIdx((ImDrawIdx)b);
        dl->PrimWriteIdx((ImDrawIdx)a), dl->PrimWriteIdx((ImDrawIdx)a2), dl->PrimWriteIdx((ImDrawIdx)b2);
    }
}

// a small repeatable pseudo-random number in 0..1 (where trees, blades of grass and petals go)
static float hash01(uint32_t x) {
    x ^= x >> 16, x *= 0x7feb352d, x ^= x >> 15, x *= 0x846ca68b, x ^= x >> 16;
    return (x & 0xFFFFFF) / 16777216.0f;
}

static ImU32 mix(ImU32 a, ImU32 b, float f) {
    ImVec4 A = ImGui::ColorConvertU32ToFloat4(a), B = ImGui::ColorConvertU32ToFloat4(b);
    return ImGui::ColorConvertFloat4ToU32(ImVec4(A.x + (B.x - A.x) * f, A.y + (B.y - A.y) * f, A.z + (B.z - A.z) * f,
                                                 A.w + (B.w - A.w) * f));
}

// A quad with a colour per corner (soft shapes such as the light shafts: no anti-aliasing needed)
static void quad_grad(ImDrawList *dl, ImVec2 a, ImVec2 b, ImVec2 c, ImVec2 d, ImU32 ca, ImU32 cb, ImU32 cc, ImU32 cd) {
    ImVec2 uv = dl->_Data->TexUvWhitePixel;
    dl->PrimReserve(6, 4);
    unsigned i = dl->_VtxCurrentIdx;
    dl->PrimWriteVtx(a, uv, ca), dl->PrimWriteVtx(b, uv, cb), dl->PrimWriteVtx(c, uv, cc), dl->PrimWriteVtx(d, uv, cd);
    dl->PrimWriteIdx((ImDrawIdx)i), dl->PrimWriteIdx((ImDrawIdx)(i + 1)), dl->PrimWriteIdx((ImDrawIdx)(i + 2));
    dl->PrimWriteIdx((ImDrawIdx)i), dl->PrimWriteIdx((ImDrawIdx)(i + 2)), dl->PrimWriteIdx((ImDrawIdx)(i + 3));
}

// ------------------------------------------------------------------ Savage Wind's own art
// An old forest at a clearing, drawn here (nothing of the game's): tall trunks fading into a green haze, the canopy
// opening at the upper right, shafts of sunlight through it, mossy rocks, ferns and tall grass swaying in the wind,
// petals drifting and fireflies. The menu and the game files card sit on the left, so the light is on the right.

// The icon's shapes are in its 1024-unit square with the mountain's summit at (512, 515): placed at `o`, `k` pixels
// per unit.
struct Place {
    ImVec2 o;
    float k;
    ImVec2 operator()(float x, float y) const { return ImVec2(o.x + (x - 512) * k, o.y + (y - 515) * k); }
};

// dir: 0 top to bottom, 1 left to right, 2 top left to bottom right, 3 top right to bottom left (across its bounds)
// dir: 0 top to bottom, 1 left to right, 2 top left to bottom right, 3 top right to bottom left (across its bounds)
static void shape(ImDrawList *dl, const Place &P, const float (*pts)[2], int n, uint32_t c0, uint32_t c1,
                  float alpha = 1, int dir = 0) {
    ImVec2 q[16];
    n = n < 16 ? n : 16;
    float y0 = 1e9f, y1 = -1e9f, x0 = 1e9f, x1 = -1e9f;
    for (int i = 0; i < n; i++) {
        q[i] = P(pts[i][0], pts[i][1]);
        y0 = fminf(y0, q[i].y), y1 = fmaxf(y1, q[i].y), x0 = fminf(x0, q[i].x), x1 = fmaxf(x1, q[i].x);
    }
    ImVec2 a = dir == 3 ? ImVec2(x1, y0) : ImVec2(x0, y0);
    ImVec2 b = dir == 0 ? ImVec2(x0, y1) : dir == 1 ? ImVec2(x1, y0) : dir == 2 ? ImVec2(x1, y1) : ImVec2(x0, y1);
    fill_grad(dl, q, n, a, b, rgba(c0, alpha), rgba(c1, alpha));
}

// Savage Wind's own plain sword (the icon's, docs/icon/icon.svg): pommel, wrapped grip, crossguard, a blade lit on
// its left half; its tip goes into whatever is drawn over it
static void sword(ImDrawList *dl, const Place &P) {
    float k = P.k;
    ImU32 edge = rgba(0x3e5170);
    // blade (its tip in the snow)
    static const float bl[][2] = {{475, 345}, {512, 345}, {512, 640}, {475, 600}};
    static const float br[][2] = {{512, 345}, {549, 345}, {549, 600}, {512, 640}};
    {
        ImVec2 o[5] = {P(472, 342), P(552, 342), P(552, 601), P(512, 645), P(472, 601)};
        fill(dl, o, 5, edge);
    }
    shape(dl, P, bl, 4, 0xeef6ff, 0xffffff, 1, 1);
    shape(dl, P, br, 4, 0xb3c6da, 0x7d93ad, 1, 1);
    // crossguard
    ImVec2 c0 = P(385, 305), c1 = P(640, 345);
    dl->AddRectFilled(ImVec2(c0.x - 2.5f * k, c0.y - 2.5f * k), ImVec2(c1.x + 2.5f * k, c1.y + 2.5f * k), edge, 12 * k);
    dl->AddRectFilledMultiColor(ImVec2(c0.x + 6 * k, c0.y), ImVec2(c1.x - 6 * k, c1.y), rgba(0xf1f6fb), rgba(0xf1f6fb),
                                rgba(0x8293a8), rgba(0x8293a8));
    dl->AddRectFilled(c0, ImVec2(c0.x + 10 * k, c1.y), rgba(0xc9d4e1), 10 * k, ImDrawFlags_RoundCornersLeft);
    dl->AddRectFilled(ImVec2(c1.x - 10 * k, c0.y), c1, rgba(0xa9b6c6), 10 * k, ImDrawFlags_RoundCornersRight);
    // grip, wrapped
    ImVec2 g0 = P(488, 200), g1 = P(536, 305);
    dl->AddRectFilled(ImVec2(g0.x - 3 * k, g0.y - 3 * k), ImVec2(g1.x + 3 * k, g1.y + 2 * k), rgba(0x241509), 14 * k);
    dl->AddRectFilledMultiColor(g0, g1, rgba(0x6b4527), rgba(0x3a2414), rgba(0x3a2414), rgba(0x6b4527));
    for (int i = 0; i < 4; i++) {
        float y = 225 + i * 24;
        dl->AddLine(P(490, y), P(534, y + 12), rgba(0xa8703f), 5 * k);
    }
    // pommel
    ImVec2 pc = P(512, 192);
    dl->AddCircleFilled(pc, 31 * k, rgba(0x3e5170), 32);
    dl->AddCircleFilled(pc, 26 * k, rgba(0x8293a8), 32);
    dl->AddCircleFilled(ImVec2(pc.x - 3 * k, pc.y - 4 * k), 20 * k, rgba(0xdbe4ee), 32);
}

// A trunk from above the window down to `ground`, wider at its roots, shaded across (dark to lit, the sun's side)
static void trunk(ImDrawList *dl, float x, float w, float ground, float lean, ImU32 dark, ImU32 lit, float H) {
    ImVec2 p[8] = {ImVec2(x - w * 0.5f + lean, -0.05f * H), ImVec2(x + w * 0.5f + lean, -0.05f * H),
                   ImVec2(x + w * 0.52f, ground - w * 0.9f), ImVec2(x + w * 0.95f, ground),
                   ImVec2(x + w * 0.2f, ground - w * 0.15f), ImVec2(x - w * 0.25f, ground - w * 0.12f),
                   ImVec2(x - w * 0.95f, ground), ImVec2(x - w * 0.52f, ground - w * 0.9f)};
    fill_grad(dl, p, 8, ImVec2(x - w * 0.6f, 0), ImVec2(x + w * 0.6f, 0), dark, lit);
}

// A blade of grass from (x, y), `h` tall, its tip `bend` aside; darker at the root
static void blade(ImDrawList *dl, float x, float y, float w, float h, float bend, ImU32 root, ImU32 tip) {
    ImVec2 p[5] = {ImVec2(x - w, y), ImVec2(x - w * 0.55f + bend * 0.3f, y - h * 0.55f), ImVec2(x + bend, y - h),
                   ImVec2(x + w * 0.55f + bend * 0.3f, y - h * 0.55f), ImVec2(x + w, y)};
    fill_grad(dl, p, 5, ImVec2(x, y), ImVec2(x + bend, y - h), root, tip);
}

// A fern frond: a stem arching from `base` (angle in radians, 0 = right, y down) with leaflets on both sides
static void frond(ImDrawList *dl, ImVec2 base, float ang, float len, float droop, ImU32 dark, ImU32 lit) {
    const int N = 12;
    ImVec2 prev = base;
    for (int i = 1; i <= N; i++) {
        float u = (float)i / N, a = ang + droop * u;
        ImVec2 p(prev.x + cosf(a) * len / N, prev.y + sinf(a) * len / N);
        float l = len * 0.16f * (1 - u * 0.75f), nx = -sinf(a), ny = cosf(a);
        ImU32 c = mix(dark, lit, u);
        for (int side : {-1, 1}) {
            ImVec2 q[3] = {prev, ImVec2(p.x + nx * l * side + cosf(a) * l * 0.3f, p.y + ny * l * side + sinf(a) * l * 0.3f), p};
            dl->AddTriangleFilled(q[0], q[1], q[2], c);
        }
        dl->AddLine(prev, p, dark, len * 0.012f + 1);
        prev = p;
    }
}

// A mossy rock: a rounded, slightly irregular outline, moss on top
static void rock(ImDrawList *dl, ImVec2 c, float r, uint32_t seed, ImU32 moss = rgba(0x6f9c3c),
                 ImU32 base = rgba(0x24321f)) {
    ImVec2 p[14];
    for (int i = 0; i < 14; i++) {
        float a = 3.14159265f + i * 3.14159265f / 13, rr = r * (0.85f + 0.25f * hash01(seed * 31 + i));
        p[i] = ImVec2(c.x + cosf(a) * rr * 1.25f, c.y + sinf(a) * rr * 0.9f);
    }
    fill_grad(dl, p, 14, ImVec2(c.x, c.y - r * 0.9f), ImVec2(c.x, c.y), moss, base);
}

static void forest_art(ImDrawList *dl, ImVec2 sz, float t) {
    float W = sz.x, H = sz.y, s = H / 720.0f;
    // depth: dark green above, the clearing's haze lower down, darker again at the floor
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, H * 0.55f), rgba(0x0a2013), rgba(0x123018), rgba(0x2b5a2c),
                                rgba(0x1d4424));
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.55f), sz, rgba(0x1d4424), rgba(0x2b5a2c), rgba(0x183a1c),
                                rgba(0x10291a));
    // the light where the canopy opens
    glow(dl, ImVec2(W * 0.80f, H * 0.16f), H * 1.0f, rgba(0xf2ffc0, 0.55f), rgba(0xa8d860, 0.20f), 0.35f);
    // far trunks in the haze, lighter towards the light
    for (uint32_t i = 0; i < 18; i++) {
        float x = (i + 0.2f + 0.6f * hash01(i * 7 + 1)) / 18 * W * 1.1f - W * 0.05f, w = H * (0.010f + 0.014f * hash01(i * 7 + 2));
        float near_sun = 1 - fminf(fabsf(x - W * 0.8f) / (W * 0.5f), 1);
        ImU32 c = mix(rgba(0x3f6a3c, 0.55f), rgba(0x9cc86c, 0.45f), near_sun);
        trunk(dl, x, w, H * (0.70f + 0.03f * hash01(i * 7 + 3)), w * (hash01(i * 7 + 4) - 0.5f) * 2, c, c, H);
    }
    // a haze over the far forest
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.48f), ImVec2(W, H * 0.70f), rgba(0xd6f0a6, 0), rgba(0xd6f0a6, 0),
                                rgba(0xd6f0a6, 0.20f), rgba(0xd6f0a6, 0.20f));
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.70f), ImVec2(W, H * 0.84f), rgba(0xd6f0a6, 0.20f), rgba(0xd6f0a6, 0.20f),
                                rgba(0xd6f0a6, 0), rgba(0xd6f0a6, 0));
    // the forest floor, lit in the clearing
    {
        ImVec2 g[11] = {ImVec2(0, H * 0.80f), ImVec2(W * 0.14f, H * 0.775f), ImVec2(W * 0.32f, H * 0.79f),
                        ImVec2(W * 0.50f, H * 0.755f), ImVec2(W * 0.66f, H * 0.735f), ImVec2(W * 0.80f, H * 0.73f),
                        ImVec2(W * 0.92f, H * 0.745f), ImVec2(W, H * 0.735f), ImVec2(W, H), ImVec2(0, H)};
        fill_grad(dl, g, 10, ImVec2(0, H * 0.73f), ImVec2(0, H), rgba(0x5a9433), rgba(0x10291a));
        glow(dl, ImVec2(W * 0.80f, H * 0.80f), H * 0.30f, rgba(0xe8ff9c, 0.35f), rgba(0xb8e070, 0.12f), 0.4f);
    }
    // middle trunks, lit on the clearing's side
    static const float mid[][3] = {{0.34f, 0.050f, 0.765f}, {0.43f, 0.036f, 0.755f}, {0.555f, 0.062f, 0.75f},
                                   {0.65f, 0.030f, 0.74f},  {0.885f, 0.045f, 0.75f}, {0.965f, 0.07f, 0.745f}};
    for (int i = 0; i < 6; i++)
        trunk(dl, W * mid[i][0], H * mid[i][1], H * mid[i][2], H * 0.01f * (i & 1 ? 1 : -1), rgba(0x172d18),
              mid[i][0] > 0.6f ? rgba(0x6a8f44) : rgba(0x3e6034), H);
    rock(dl, ImVec2(W * 0.60f, H * 0.785f), H * 0.045f, 1);
    rock(dl, ImVec2(W * 0.705f, H * 0.765f), H * 0.03f, 2);
    rock(dl, ImVec2(W * 0.935f, H * 0.80f), H * 0.055f, 3);
    // shafts of sunlight through the canopy, slowly breathing
    for (uint32_t i = 0; i < 8; i++) {
        float x0 = W * (0.60f + 0.40f * hash01(i * 5 + 40)), a = 1.98f + 0.16f * hash01(i * 5 + 41);  // (down and left)
        float w0 = H * (0.015f + 0.035f * hash01(i * 5 + 42)), len = H * (0.9f + 0.4f * hash01(i * 5 + 43));
        float k = (0.14f + 0.12f * hash01(i * 5 + 44)) * (0.7f + 0.3f * sinf(t * (0.25f + 0.2f * hash01(i * 5 + 45)) + i * 1.7f));
        ImVec2 dir(cosf(a), sinf(a)), n(-dir.y, dir.x), a0(x0, -H * 0.04f), a1(a0.x + dir.x * len, a0.y + dir.y * len);
        float w1 = w0 * 2.6f;
        ImU32 top = rgba(0xf4ffc8, k), end = rgba(0xf4ffc8, 0);
        quad_grad(dl, ImVec2(a0.x - n.x * w0, a0.y - n.y * w0), ImVec2(a0.x + n.x * w0, a0.y + n.y * w0),
                  ImVec2(a1.x + n.x * w1, a1.y + n.y * w1), ImVec2(a1.x - n.x * w1, a1.y - n.y * w1), top, top, end, end);
    }
    // the canopy: dark leaves along the top, opening above the clearing, lit at its edge
    for (uint32_t i = 0; i < 46; i++) {
        float x = hash01(i * 3 + 70) * W * 1.1f - W * 0.05f, r = H * (0.05f + 0.10f * hash01(i * 3 + 71));
        float gap = fabsf(x - W * 0.80f) < W * 0.13f ? 1 : 0;
        float y = H * (-0.06f + 0.16f * hash01(i * 3 + 72)) - gap * H * 0.12f + (x < W * 0.3f ? H * 0.06f : 0);
        dl->AddCircleFilled(ImVec2(x, y), r, rgba(0x0b1f0f, 0.97f), 28);
        float toward = x < W * 0.8f ? 1.0f : -1.0f;  // (the leaves facing the light)
        dl->AddCircleFilled(ImVec2(x + toward * r * 0.35f, y + r * 0.35f), r * 0.55f, rgba(0x2c5524, 0.85f), 24);
    }
    // near trunks, framing the clearing
    trunk(dl, W * 0.035f, H * 0.12f, H * 0.95f, 0, rgba(0x0b1a0c), rgba(0x22401f), H);
    trunk(dl, W * 0.25f, H * 0.075f, H * 0.90f, H * 0.02f, rgba(0x0d1e0e), rgba(0x2a4a22), H);
    trunk(dl, W * 1.0f, H * 0.14f, H * 0.97f, -H * 0.01f, rgba(0x2c4a24), rgba(0x0b1a0c), H);
    // ferns at the sides, nodding in the wind
    for (uint32_t i = 0; i < 14; i++) {
        bool right = i >= 7;
        float bx = right ? W * (0.70f + 0.30f * hash01(i + 90)) : W * (0.02f + 0.30f * hash01(i + 90));
        ImVec2 b(bx, H * (0.90f + 0.08f * hash01(i + 91)));
        float ang = (right ? -2.2f : -0.95f) + 0.5f * (hash01(i + 92) - 0.5f) + 0.04f * sinf(t * 0.9f + i);
        frond(dl, b, ang, H * (0.16f + 0.10f * hash01(i + 93)), right ? -0.9f : 0.9f, rgba(0x163d18),
              right ? rgba(0x7cc043) : rgba(0x3f7a2c));
    }
    // grass: short in the lit clearing, tall in front, all swaying
    for (uint32_t i = 0; i < 170; i++) {
        float x = hash01(i * 4 + 200) * W, y = H * (0.75f + 0.08f * hash01(i * 4 + 201)), h = H * (0.02f + 0.04f * hash01(i * 4 + 202));
        float light = 1 - fminf(fabsf(x - W * 0.78f) / (W * 0.45f), 1);
        float bend = h * (0.25f * sinf(t * 1.1f + x * 0.01f) + 0.15f);
        blade(dl, x, y, H * 0.003f, h, bend, rgba(0x2a5a20), mix(rgba(0x5f9a34), rgba(0xd8f58a), light));
    }
    {  // in the clearing's light: Savage Wind's sword in a mossy stone (the old tale, not any game's sword)
        ImVec2 c(W * 0.80f, H * 0.775f);
        float r = H * 0.075f, k = H * 0.30f / 429.0f;  // (the sword from its pommel to the stone: 429 units)
        Place S{ImVec2(c.x, c.y - r * 0.85f - (560 - 515) * k), k};
        glow(dl, S(512, 400), 360 * k, rgba(0xf4ffd0, 0.45f), rgba(0xd8f0a0, 0.15f), 0.4f);
        sword(dl, S);
        // a rough stone block, worn at its edges: grey below, moss on top
        ImVec2 b[8] = {ImVec2(c.x - 1.15f * r, c.y), ImVec2(c.x - 1.05f * r, c.y - 0.62f * r),
                       ImVec2(c.x - 0.86f * r, c.y - 0.90f * r), ImVec2(c.x - 0.2f * r, c.y - 0.97f * r),
                       ImVec2(c.x + 0.62f * r, c.y - 0.93f * r), ImVec2(c.x + 1.0f * r, c.y - 0.7f * r),
                       ImVec2(c.x + 1.12f * r, c.y - 0.25f * r), ImVec2(c.x + 1.18f * r, c.y)};
        fill_grad(dl, b, 8, ImVec2(c.x - r, c.y - r), ImVec2(c.x + r, c.y), rgba(0x7d8a74), rgba(0x353f31));
        ImVec2 m[7] = {ImVec2(c.x - 0.95f * r, c.y - 0.80f * r), ImVec2(c.x - 0.86f * r, c.y - 0.92f * r),
                       ImVec2(c.x - 0.2f * r, c.y - 0.99f * r), ImVec2(c.x + 0.62f * r, c.y - 0.95f * r),
                       ImVec2(c.x + 0.95f * r, c.y - 0.68f * r), ImVec2(c.x + 0.3f * r, c.y - 0.72f * r),
                       ImVec2(c.x - 0.4f * r, c.y - 0.62f * r)};
        fill_grad(dl, m, 7, ImVec2(c.x, c.y - r), ImVec2(c.x, c.y - 0.6f * r), rgba(0xb6dc6a), rgba(0x5f8f34));
    }
    for (uint32_t i = 0; i < 300; i++) {
        float x = hash01(i * 4 + 900) * W * 1.04f - W * 0.02f, y = H * (0.86f + 0.17f * hash01(i * 4 + 901));
        float h = H * (0.07f + 0.14f * hash01(i * 4 + 902)) * (0.7f + (y / H - 0.86f) * 2.5f);
        float light = 1 - fminf(fabsf(x - W * 0.78f) / (W * 0.55f), 1);
        float bend = h * (0.22f * sinf(t * 1.3f + x * 0.006f + hash01(i * 4 + 903) * 2) + 0.12f);
        blade(dl, x, y, H * (0.004f + 0.004f * hash01(i * 4 + 903)), h, bend, rgba(0x0b220d),
              mix(rgba(0x3f7f2a), rgba(0xc8ef6e), light));
    }
    // petals drifting down through the light, and fireflies
    for (uint32_t i = 0; i < 80; i++) {
        float vx = 10 + 20 * hash01(i * 6 + 400), vy = 8 + 14 * hash01(i * 6 + 401), r = (1.6f + 1.6f * hash01(i * 6 + 402)) * s;
        float x = fmodf(hash01(i * 6 + 403) * W - t * vx * s + (W + 40) * 8, W + 40) - 20;
        float y = fmodf(hash01(i * 6 + 404) * H + t * vy * s, H + 40) - 20;
        x += sinf(t * 1.4f + i) * 8 * s;
        ImU32 c = hash01(i * 6 + 405) < 0.5f ? rgba(0xffe4ec, 0.85f) : rgba(0xfff4d8, 0.85f);
        dl->AddEllipseFilled(ImVec2(x, y), ImVec2(r, r * 0.55f), c, t * (1 + hash01(i)) + i, 10);
    }
    for (uint32_t i = 0; i < 26; i++) {
        float k = sinf(t * (1.1f + hash01(i * 3 + 600)) + i * 2.1f);
        if (k <= 0) continue;
        ImVec2 p(W * (0.38f + 0.6f * hash01(i * 3 + 601)) + sinf(t * 0.3f + i) * 30 * s,
                 H * (0.45f + 0.45f * hash01(i * 3 + 602)) + cosf(t * 0.4f + i * 1.3f) * 20 * s);
        glow(dl, p, 9 * s, rgba(0xf6ff9a, 0.7f * k), rgba(0xd8f060, 0.2f * k), 0.3f);
    }
    // darker at the edges
    ImU32 v = rgba(0x040c06, 0.55f), z = rgba(0x040c06, 0);
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, H * 0.22f), v, v, z, z);
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.82f), sz, z, z, v, v);
}


// ------------------------------------------------------------------ MvDK Recomp's own art
// A toy-works building site at sunset: a far city, a lattice tower, red steel girders with rivets climbing to the
// right joined by yellow ladders, a crane with its hook swinging, a wind-up key turning in a toy box on the top beam,
// sparks drifting. Original art; the menu sits on the left, so the girders are on the right.

// A steel girder from a to b, `th` thick: flanges, a truss web between them and rivets along both flanges
static void girder(ImDrawList *dl, ImVec2 a, ImVec2 b, float th, float s) {
    ImVec2 d(b.x - a.x, b.y - a.y);
    float len = sqrtf(d.x * d.x + d.y * d.y);
    ImVec2 u(d.x / len, d.y / len), n(-u.y, u.x);  // (n points down for a left-to-right beam)
    auto at = [&](float along, float across) { return ImVec2(a.x + u.x * along + n.x * across, a.y + u.y * along + n.y * across); };
    // shadow under it
    quad_grad(dl, at(0, th * 0.5f), at(len, th * 0.5f), at(len, th * 0.95f), at(0, th * 0.95f), rgba(0x1a0610, 0.45f),
              rgba(0x1a0610, 0.45f), rgba(0x1a0610, 0), rgba(0x1a0610, 0));
    // the web's dark back
    quad_grad(dl, at(0, -th * 0.5f), at(len, -th * 0.5f), at(len, th * 0.5f), at(0, th * 0.5f), rgba(0x5a0e14),
              rgba(0x5a0e14), rgba(0x2c050a), rgba(0x2c050a));
    // the truss: zigzag bars
    float f = th * 0.2f, cell = th * 1.1f;
    int nc = (int)(len / cell);
    if (nc < 1) nc = 1;
    cell = len / nc;
    for (int i = 0; i < nc; i++) {
        ImVec2 p0 = at(i * cell, (i & 1 ? 1 : -1) * (th * 0.5f - f)), p1 = at((i + 1) * cell, (i & 1 ? -1 : 1) * (th * 0.5f - f));
        dl->AddLine(p0, p1, rgba(0xc8282c), th * 0.16f);
        dl->AddLine(at(i * cell, -th * 0.5f + f), at(i * cell, th * 0.5f - f), rgba(0x9a1a20), th * 0.10f);
    }
    // flanges: lit on top
    quad_grad(dl, at(0, -th * 0.5f), at(len, -th * 0.5f), at(len, -th * 0.5f + f), at(0, -th * 0.5f + f), rgba(0xff8a6a),
              rgba(0xff8a6a), rgba(0xe0383a), rgba(0xe0383a));
    quad_grad(dl, at(0, th * 0.5f - f), at(len, th * 0.5f - f), at(len, th * 0.5f), at(0, th * 0.5f), rgba(0xd2302f),
              rgba(0xd2302f), rgba(0x8a141a), rgba(0x8a141a));
    // rivets
    int nr = (int)(len / (th * 0.55f));
    for (int i = 1; i < nr; i++) {
        float x = len * i / nr;
        for (int side = -1; side <= 1; side += 2) {
            ImVec2 c = at(x, side * (th * 0.5f - f * 0.5f));
            dl->AddCircleFilled(c, f * 0.32f, rgba(0x6a0c12), 8);
            dl->AddCircleFilled(ImVec2(c.x - f * 0.08f, c.y - f * 0.08f), f * 0.2f, rgba(0xffc0a8), 8);
        }
    }
    (void)s;
}

// A ladder from top (x, y0) down to y1, `w` wide
static void ladder(ImDrawList *dl, float x, float y0, float y1, float w, float s) {
    float r = w * 0.14f;
    dl->AddRectFilled(ImVec2(x - w * 0.5f + r * 0.6f, y0 + r), ImVec2(x + w * 0.5f + r * 0.6f, y1 + r), rgba(0x1a0610, 0.35f));
    for (float y = y0 + w * 0.35f; y < y1 - w * 0.1f; y += w * 0.45f)
        dl->AddRectFilledMultiColor(ImVec2(x - w * 0.5f, y), ImVec2(x + w * 0.5f, y + r * 0.9f), rgba(0xffe27a),
                                    rgba(0xffe27a), rgba(0xc08a1c), rgba(0xc08a1c));
    for (int side = -1; side <= 1; side += 2) {
        float cx = x + side * w * 0.5f;
        dl->AddRectFilledMultiColor(ImVec2(cx - r * 0.5f, y0), ImVec2(cx + r * 0.5f, y1), rgba(0xfff0a0), rgba(0xd89a24),
                                    rgba(0xd89a24), rgba(0xfff0a0));
    }
    (void)s;
}

// A lattice column (the tower's legs and braces), dark against the sky
static void lattice(ImDrawList *dl, float x, float w, float top, float bottom, ImU32 c, float lw) {
    dl->AddLine(ImVec2(x, top), ImVec2(x, bottom), c, lw * 1.6f);
    dl->AddLine(ImVec2(x + w, top), ImVec2(x + w, bottom), c, lw * 1.6f);
    for (float y = top; y < bottom; y += w) {
        dl->AddLine(ImVec2(x, y), ImVec2(x + w, y + w), c, lw);
        dl->AddLine(ImVec2(x + w, y), ImVec2(x, y + w), c, lw);
        dl->AddLine(ImVec2(x, y), ImVec2(x + w, y), c, lw);
    }
}

static void girder_art(ImDrawList *dl, ImVec2 sz, float t) {
    float W = sz.x, H = sz.y, s = H / 720.0f;
    // sunset sky: deep blue above, rose and orange at the horizon
    float hz = H * 0.66f;
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, H * 0.35f), rgba(0x0c1036), rgba(0x1a1a52), rgba(0x5a2a78), rgba(0x3a2268));
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.35f), ImVec2(W, hz), rgba(0x3a2268), rgba(0x5a2a78), rgba(0xff8a4c), rgba(0xd8586a));
    // stars, twinkling in the dark part
    for (uint32_t i = 0; i < 70; i++) {
        float k = 0.5f + 0.5f * sinf(t * (0.8f + hash01(i * 3 + 7)) + i);
        ImVec2 p(hash01(i * 3 + 5) * W, hash01(i * 3 + 6) * H * 0.38f);
        dl->AddCircleFilled(p, (0.8f + 1.2f * hash01(i * 3 + 8)) * s, rgba(0xfff6e0, 0.25f + 0.6f * k * (1 - p.y / (H * 0.38f))), 6);
    }
    // the low sun behind the site
    glow(dl, ImVec2(W * 0.74f, hz), H * 0.75f, rgba(0xffe0a0, 0.65f), rgba(0xff9a5a, 0.22f), 0.3f);
    dl->AddCircleFilled(ImVec2(W * 0.74f, hz - H * 0.02f), H * 0.10f, rgba(0xffe8b0, 0.9f), 48);
    // the far city: blocks with lit windows
    for (uint32_t i = 0; i < 34; i++) {
        float x = (i + hash01(i * 5 + 300) * 0.4f) / 34 * W * 1.05f - W * 0.02f, w = W * (0.022f + 0.02f * hash01(i * 5 + 301));
        float h = H * (0.06f + 0.16f * hash01(i * 5 + 302));
        dl->AddRectFilled(ImVec2(x, hz - h), ImVec2(x + w, hz + 2), rgba(0x2a1640, 0.92f));
        for (float wy = hz - h + 6 * s; wy < hz - 6 * s; wy += 9 * s)
            for (float wx = x + 4 * s; wx < x + w - 5 * s; wx += 8 * s) {
                uint32_t q = (uint32_t)(wx * 13 + wy * 7);
                if (hash01(q) < 0.62f) continue;
                float on = sinf(t * 0.3f + hash01(q + 1) * 40) > -0.6f ? 1 : 0;
                dl->AddRectFilled(ImVec2(wx, wy), ImVec2(wx + 3 * s, wy + 4 * s), rgba(0xffd27a, 0.75f * on));
            }
    }
    // haze over the city
    dl->AddRectFilledMultiColor(ImVec2(0, hz - H * 0.12f), ImVec2(W, hz), rgba(0xff9a6a, 0), rgba(0xff9a6a, 0),
                                rgba(0xff9a6a, 0.28f), rgba(0xff9a6a, 0.28f));
    // the ground: the site's dark yard, a hazard-striped kerb at its edge
    dl->AddRectFilledMultiColor(ImVec2(0, hz), sz, rgba(0x2a1a2e), rgba(0x3a2230), rgba(0x0e0a14), rgba(0x0e0a14));
    {
        float y0 = H * 0.86f, y1 = y0 + H * 0.035f, st = H * 0.06f;
        dl->AddRectFilled(ImVec2(0, y0), ImVec2(W, y1), rgba(0x15101a));
        for (float x = -st; x < W + st; x += st * 2) {
            ImVec2 q[4] = {ImVec2(x, y1), ImVec2(x + st, y1), ImVec2(x + st * 1.6f, y0), ImVec2(x + st * 0.6f, y0)};
            fill(dl, q, 4, rgba(0xf2b632, 0.9f));
        }
        dl->AddRectFilledMultiColor(ImVec2(0, y1), ImVec2(W, y1 + H * 0.02f), rgba(0, 0.5f), rgba(0, 0.5f), rgba(0, 0), rgba(0, 0));
    }
    // the tower behind the girders, and the crane on it
    ImU32 dark = rgba(0x1a0c22, 0.95f);
    float tx = W * 0.90f, tw = H * 0.07f;
    lattice(dl, tx, tw, H * 0.10f, H * 0.87f, dark, 3 * s);
    lattice(dl, W * 0.50f, H * 0.05f, H * 0.36f, H * 0.87f, rgba(0x1a0c22, 0.8f), 2.5f * s);
    {   // the crane's arm, out over the site to the left, and its hook swinging
        float ay = H * 0.10f;
        dl->AddLine(ImVec2(tx + tw * 0.5f, ay - H * 0.06f), ImVec2(W * 0.56f, ay), dark, 3 * s);
        dl->AddLine(ImVec2(tx + tw * 0.5f, ay - H * 0.06f), ImVec2(W * 1.02f, ay), dark, 3 * s);
        for (int side = 0; side < 2; side++) dl->AddLine(ImVec2(W * 0.56f, ay + side * H * 0.025f), ImVec2(W * 1.02f, ay + side * H * 0.025f), dark, 3 * s);
        for (float x = W * 0.56f; x < W * 1.0f; x += H * 0.025f)
            dl->AddLine(ImVec2(x, ay), ImVec2(x + H * 0.025f, ay + H * 0.025f), dark, 2 * s);
        float sw = 0.08f * sinf(t * 0.7f), len = H * 0.22f, hx = W * 0.66f;
        ImVec2 top(hx, ay + H * 0.025f), hook(hx + sinf(sw) * len, top.y + cosf(sw) * len);
        dl->AddLine(top, hook, rgba(0x2a1a30), 2 * s);
        dl->AddCircle(ImVec2(hook.x, hook.y + 9 * s), 8 * s, rgba(0x3a2a40), 12, 4 * s);
        dl->AddRectFilled(ImVec2(hook.x - 7 * s, hook.y - 6 * s), ImVec2(hook.x + 7 * s, hook.y + 2 * s), rgba(0xf2b632));
        // the warning light on top, blinking
        if (fmodf(t, 1.6f) < 0.8f) glow(dl, ImVec2(tx + tw * 0.5f, ay - H * 0.07f), 14 * s, rgba(0xff4040, 0.95f), rgba(0xff2020, 0.3f), 0.3f);
    }
    // the girders climbing to the right, each sloping the other way, joined by ladders
    float th = H * 0.05f;
    struct Beam { float x0, y0, x1, y1; };
    static const Beam beams[] = {{0.40f, 0.835f, 1.02f, 0.80f}, {0.46f, 0.62f, 1.02f, 0.655f},
                                 {0.42f, 0.47f, 0.98f, 0.435f}, {0.54f, 0.28f, 0.96f, 0.30f}};
    static const float ladders[][3] = {{0.92f, 0, 1}, {0.55f, 1, 2}, {0.86f, 2, 3}};  // (x, from beam, to beam)
    auto beam_y = [&](int b, float x) {
        const Beam &B = beams[b];
        return H * (B.y0 + (B.y1 - B.y0) * (x - B.x0) / (B.x1 - B.x0));
    };
    for (auto &l : ladders) {
        float x = l[0];
        ladder(dl, W * x, beam_y((int)l[2], x) + th * 0.4f, beam_y((int)l[1], x) - th * 0.5f, H * 0.045f, s);
    }
    for (auto &B : beams) girder(dl, ImVec2(W * B.x0, H * B.y0), ImVec2(W * B.x1, H * B.y1), th, s);
    {   // a toy box on the top beam with its wind-up key turning
        float bx = W * 0.70f, by = beam_y(3, 0.70f) - th * 0.5f, bw = H * 0.09f;
        dl->AddRectFilledMultiColor(ImVec2(bx - bw * 0.5f, by - bw * 0.8f), ImVec2(bx + bw * 0.5f, by), rgba(0x4a8cff),
                                    rgba(0x2a5ad8), rgba(0x1a3a98), rgba(0x2a5ad8));
        dl->AddRect(ImVec2(bx - bw * 0.5f, by - bw * 0.8f), ImVec2(bx + bw * 0.5f, by), rgba(0x0c1a50), 0, 0, 2.5f * s);
        dl->AddRectFilled(ImVec2(bx - bw * 0.08f, by - bw * 0.8f), ImVec2(bx + bw * 0.08f, by), rgba(0xffd84a));
        float a = t * 2.0f, kc = fabsf(cosf(a)) * 0.9f + 0.1f;  // (the key turning: its bow seen edge-on and flat)
        ImVec2 kb(bx + bw * 0.5f + bw * 0.15f, by - bw * 0.4f);
        dl->AddLine(ImVec2(bx + bw * 0.5f, kb.y), kb, rgba(0xc8962a), 4 * s);
        for (int side = -1; side <= 1; side += 2)
            dl->AddEllipseFilled(ImVec2(kb.x + bw * 0.16f, kb.y + side * bw * 0.17f * kc), ImVec2(bw * 0.15f, bw * 0.16f * kc),
                                 mix(rgba(0xa8781c), rgba(0xffe080), kc), 0, 20);
        dl->AddCircleFilled(ImVec2(kb.x + bw * 0.16f, kb.y), bw * 0.06f, rgba(0x8a5e12), 12);
        glow(dl, ImVec2(bx, by - bw * 0.4f), bw * 1.2f, rgba(0xfff0c0, 0.18f), rgba(0xfff0c0, 0.05f), 0.4f);
    }
    // bolts and a spanner on the yard, steel beams stacked
    for (int i = 0; i < 3; i++) girder(dl, ImVec2(W * (0.08f + i * 0.015f), H * (0.95f - i * 0.04f)), ImVec2(W * (0.34f + i * 0.01f), H * (0.95f - i * 0.04f)), H * 0.035f, s);
    // sparks drifting up from a welder on the second beam
    ImVec2 weld(W * 0.66f, beam_y(1, 0.66f) - th * 0.5f);
    glow(dl, weld, 26 * s * (0.8f + 0.2f * sinf(t * 23)), rgba(0xfff8e0, 0.9f), rgba(0x9ad8ff, 0.3f), 0.25f);
    for (uint32_t i = 0; i < 40; i++) {
        float life = fmodf(t * (0.6f + 0.5f * hash01(i * 4 + 500)) + hash01(i * 4 + 501), 1.0f);
        float vx = (hash01(i * 4 + 502) - 0.5f) * 160 * s, vy = -(60 + 120 * hash01(i * 4 + 503)) * s;
        ImVec2 p(weld.x + vx * life, weld.y + vy * life + 220 * s * life * life);
        dl->AddCircleFilled(p, 2.0f * s * (1 - life) + 0.6f * s, rgba(0xffd070, 0.95f * (1 - life)), 6);
    }
    // dust in the low sun
    for (uint32_t i = 0; i < 60; i++) {
        float x = fmodf(hash01(i * 6 + 700) * W + t * (6 + 12 * hash01(i * 6 + 701)) * s, W + 40) - 20;
        float y = H * (0.2f + 0.6f * hash01(i * 6 + 702)) + sinf(t * 0.8f + i) * 10 * s;
        dl->AddCircleFilled(ImVec2(x, y), (0.8f + 1.4f * hash01(i * 6 + 703)) * s, rgba(0xffe6c0, 0.35f), 6);
    }
    // darker at the edges
    ImU32 v = rgba(0x06040e, 0.55f), z = rgba(0x06040e, 0);
    dl->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(W, H * 0.18f), v, v, z, z);
    dl->AddRectFilledMultiColor(ImVec2(0, H * 0.88f), sz, z, z, v, v);
}

void splash_draw(ImDrawList *dl, ImVec2 sz, float t) {
    if (!g_tex) { girder_art(dl, sz, t); return; }
    (void)forest_art;
    // the picture fills the window (cropped to its shape, centred)
    float ia = (float)g_tex_w / g_tex_h, da = sz.x / sz.y;
    ImVec2 uv0(0, 0), uv1(1, 1);
    if (ia > da) uv0.x = (1 - da / ia) * 0.5f, uv1.x = 1 - uv0.x;
    else uv0.y = (1 - ia / da) * 0.5f, uv1.y = 1 - uv0.y;
    dl->AddImage(g_tex, ImVec2(0, 0), sz, uv0, uv1);
    dl->AddRectFilled(ImVec2(0, 0), sz, IM_COL32(4, 8, 20, 56));  // (a touch darker: the text stays the brightest)
}
