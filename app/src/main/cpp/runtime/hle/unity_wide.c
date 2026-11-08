// Wide screens for Nine Sols (Unity 2022.3 on the Switch). Unity's player asks one function for the size of its
// screen: 1280x720 handheld, 1920x1080 docked (main 0x7000c73964 in Nine Sols 1.1.x: GetScreenResolution(int *w,
// int *h); tools/gen.py POST_HOOKS, found by its code). Everything follows from it - the back buffer, the cameras' aspect
// (Camera.aspect is the target's), the UI canvases' scaler. With Video > Fill wide screens on (g_settings.wide_view),
// the width it returns becomes the height times the phone's (or window's) shape, so the game itself draws a wider
// view - no stretched 16:9 picture - and its HUD anchors to the real edges. Those targets aren't 16:9, so the
// renderer's own widening of 16:9 targets (vulkan/textures.c rs_class) leaves them at their size. Unity's Switch
// backend also makes its display (window) textures 1920x1080 itself: those widths are patched (gen.py INSN_PATCHES,
// rt_unity_display_width).
// SAVAGEWIND_UNITY_ASPECT=<w/h>: another shape (tests: 2.37 for 21:9, 3.56 for 32:9).
#include <SDL3/SDL.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

#include "../hle.h"
#include "../settings.h"

static double screen_aspect(void) {
    const char *e = getenv("SAVAGEWIND_UNITY_ASPECT");
    if (e && atof(e) > 0.5) return atof(e);
    const SDL_DisplayMode *m = SDL_GetCurrentDisplayMode(SDL_GetPrimaryDisplay());
    if (!m || m->w <= 0 || m->h <= 0) return 16.0 / 9.0;
    double a = m->w > m->h ? (double)m->w / m->h : (double)m->h / m->w;  // (landscape, whatever the phone reports)
    return a;
}

// The width for a height of h: the screen's shape, or 0 (the game's own) when off or 16:9 or taller. Decided once, at
// boot (Unity sizes its back buffer and window once): Video > Fill wide screens takes effect at the next start.
static uint32_t wide_width(uint32_t h) {
    static int on = -1;
    static double a;
    if (on < 0) {
        // (SAVAGEWIND_UNITY_WIDE=1 only: Nine Sols draws its views into 1920x1080 render textures of its own and fits
        // them into the screen, so a wider screen alone only moved the 16:9 picture to its left. The wide view is
        // rt_unity_ortho's instead, below.)
        const char *e = getenv("SAVAGEWIND_UNITY_WIDE");
        a = screen_aspect();
        on = g_settings.wide_view && e && atoi(e) && a > 16.0 / 9.0 + 0.01;
    }
    if (!on || !h) return 0;
    uint32_t w = ((uint32_t)lround(h * a) + 7) & ~7u;  // (a multiple of 8: block-linear tiles, the halves of bloom)
    return w > 16384 ? 16384 : w;
}

// (tools/gen.py POST_HOOKS: after the game's function, with its two out-pointers)
void rt_unity_screen_resolution(Cpu *c, uint64_t pw, uint64_t ph) {
    (void)c;
    if (!pw || !ph) return;
    uint32_t w = LD32(pw), h = LD32(ph), nw = wide_width(h);
    if (!nw || nw <= w) return;
    *(uint32_t *)(uintptr_t)pw = nw;
    static uint32_t logged;
    if (logged != nw) {
        logged = nw;
        LOG("[wide] Unity screen %ux%u -> %ux%u\n", w, h, nw, h);
    }
}

// (tools/gen.py INSN_PATCHES: `mov w1, #1920` before the display textures' nvnTextureBuilderSetSize(b, 1920, 1080))
uint32_t rt_unity_display_width(void) {
    uint32_t nw = wide_width(1080);
    return nw > 1920 ? nw : 1920;
}

// Wide screens, the way that works for Nine Sols: the renderer draws every 16:9 target at the window's shape
// (Video > Fill wide screens: vulkan/textures.c RS_OUT, output_scale.c), which alone stretches the picture; the game's
// 2D cameras then get an orthographic projection that much wider (Matrix4x4f::SetOrtho, main 0x70007c0a68 in 1.1.x,
// tools/gen.py POST_HOOKS), so they show more of the world to the sides instead. Only a camera's own projection: centred
// (no translation) at 16:9 - Graphics.Blit's ortho(0, 1, 0, 1) and the UI's pixel projections keep theirs.
float output_view_shape(void);
void rt_unity_ortho(Cpu *c, uint64_t m, uint64_t x1) {
    (void)c, (void)x1;
    float k = output_view_shape();
    if (!m || k < 1.005f) return;  // (16:9, or widening off)
    float *f = (float *)(uintptr_t)m;  // column-major: m00 [0], m11 [5], translation x / y [12] / [13]
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("SAVAGEWIND_LOG_ORTHO") ? 400 : 0;
    if (dbg > 0) { dbg--; LOG("[wide] ortho m00 %.5f m11 %.5f t %.4f %.4f lr %llx\n", f[0], f[5], f[12], f[13], (unsigned long long)c->x[30]); }
    if (f[0] <= 0 || f[5] <= 0 || fabsf(f[12]) > 1e-4f || fabsf(f[13]) > 1e-4f) return;
    float aspect = f[5] / f[0];
    if (fabsf(aspect - 16.0f / 9.0f) > 0.01f) return;
    f[0] /= k;
    static int logged;
    if (logged++ < 3) LOG("[wide] ortho camera widened x%.3f (half height %.2f)\n", k, 1.0f / f[5]);
}

// (tools/gen.py POST_HOOKS: Matrix4x4f::SetPerspective, main 0x70007c094c) a perspective camera's projection at 16:9,
// centred: its horizontal scale (cot(fovy / 2) / aspect) made that much smaller - the same wider view as rt_unity_ortho
void rt_unity_persp(Cpu *c, uint64_t m, uint64_t x1) {
    (void)c, (void)x1;
    float k = output_view_shape();
    if (!m || k < 1.005f) return;
    float *f = (float *)(uintptr_t)m;  // m00 [0], m11 [5], the off-centre terms [8] / [9]
    if (f[0] <= 0 || f[5] <= 0 || fabsf(f[8]) > 1e-4f || fabsf(f[9]) > 1e-4f) return;
    if (fabsf(f[5] / f[0] - 16.0f / 9.0f) > 0.01f) return;
    f[0] /= k;
    static int logged;
    if (logged++ < 3) LOG("[wide] perspective camera widened x%.3f\n", k);
}
