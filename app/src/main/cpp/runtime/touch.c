// On-screen touch controls (Controls > Touch controls, off by default).
//
// The screen, in units of its height (x from 0 to its aspect, y from 0 at the top to 1):
//   - the Switch's buttons where a Switch has them: A B X Y at the bottom right, the d-pad right of the left stick,
//     L / ZL and R / ZR in the top corners, - and + at the top centre, the stick clicks next to the sticks
//   - the rest of the left part: a floating left stick, its base where the finger lands (dragged along past its rim)
//   - anywhere else: a drag turns the camera, through the same camera input as the mouse (runtime/hle/input.c
//     input_cam_frame)
// A button stays held while its finger is down, wherever it moves. Fingers are tracked one by one, so a stick, a
// camera drag and buttons work together. Using a controller or the keyboard hides the overlay until the next touch.
// The overlay is drawn by runtime/ui/menu.mm (touch_overlay_draw).
#include "touch.h"

#include <SDL3/SDL.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#include "hle.h"
#include "input_bind.h"
#include "settings.h"

#define MAX_FINGERS 10
#define STICK_R 0.11f        // the stick's reach (screen heights)
#define STICK_ZONE_X 0.40f   // the floating stick's part of the screen: left of this fraction of the width ...
#define STICK_ZONE_Y 0.22f   // ... and below this
#define LOOK_DEG 180.0       // the camera turns this far for a drag the screen's height
#define HIT_SLACK 1.3f       // a button takes a touch this much past its drawn radius
#define MIN_PRESS_MS 60      // a quick tap still holds its button this long (the game polls once a frame)
enum { ROLE_NONE = 0, ROLE_BUTTON = 1, ROLE_STICK = 100, ROLE_LOOK = 101 };  // (0: a zeroed finger is free)

typedef struct { int button; const char *label; float x, y, r; } Btn;

// The layout for a screen of this aspect (width / height)
static int layout(float a, Btn *b) {
    int n = 0;
    const float fx = a - 0.22f, fy = 0.66f, fo = 0.12f, fr = 0.062f;  // A B X Y (a Switch's: A right, B bottom)
    b[n++] = (Btn){BIND_A, "A", fx + fo, fy, fr};
    b[n++] = (Btn){BIND_B, "B", fx, fy + fo, fr};
    b[n++] = (Btn){BIND_X, "X", fx, fy - fo, fr};
    b[n++] = (Btn){BIND_Y, "Y", fx - fo, fy, fr};
    // (MvDK: L and R - the camera's look around in a level, the world in the menus - at the screen's sides, clear of
    // the lives counter and the item box at the top left and the timer at the top right; no ZL / ZR or stick clicks,
    // which the game doesn't use)
    b[n++] = (Btn){BIND_L, "L", 0.10f, 0.42f, 0.065f};
    b[n++] = (Btn){BIND_R, "R", a - 0.10f, 0.36f, 0.065f};
    b[n++] = (Btn){BIND_MINUS, "-", a * 0.5f - 0.10f, 0.07f, 0.045f};
    b[n++] = (Btn){BIND_PLUS, "+", a * 0.5f + 0.10f, 0.07f, 0.045f};
    const float dx = 0.60f, dy = 0.80f, d = 0.085f, dr = 0.05f;  // d-pad
    b[n++] = (Btn){BIND_LEFT, "<", dx - d, dy, dr};
    b[n++] = (Btn){BIND_UP, "^", dx, dy - d, dr};
    b[n++] = (Btn){BIND_RIGHT, ">", dx + d, dy, dr};
    b[n++] = (Btn){BIND_DOWN, "v", dx, dy + d, dr};
    return n;
}

typedef struct {
    SDL_FingerID id;
    int role;      // ROLE_*, or ROLE_BUTTON + the layout's button index
    float x, y;    // last position (screen heights)
} Finger;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;  // fingers and the stick (main thread; the overlay reads)
static Finger fingers[MAX_FINGERS];
static float stick_bx, stick_by, stick_kx, stick_ky;  // the stick's base and knob while held
static float aspect = 2.0f;                           // the window's, at the last touch

static _Atomic uint64_t buttons;
static uint64_t press_ms[64];          // when each button was last pressed (main thread)
static _Atomic uint64_t short_bits;    // buttons let go before MIN_PRESS_MS ...
static _Atomic uint64_t short_until;   // ... kept held until then (the latest of them)
static _Atomic int32_t stick_x, stick_y;
static _Atomic int64_t look_mx, look_my;  // camera drag since the last take, millidegrees
static _Atomic bool hidden;               // a controller / the keyboard was used since the last touch

static bool enabled(void) { return g_settings.touch_controls; }
bool touch_active(void) { return enabled() && !hidden; }

static void publish_locked(void) {
    Btn b[TOUCH_MAX_BUTTONS];
    int n = layout(aspect, b);
    uint64_t bits = 0;
    bool stick = false;
    for (int i = 0; i < MAX_FINGERS; i++) {
        int r = fingers[i].role;
        if (r >= ROLE_BUTTON && r < ROLE_BUTTON + n) bits |= 1ull << b[r - ROLE_BUTTON].button;
        if (r == ROLE_STICK) stick = true;
    }
    uint64_t now = SDL_GetTicks(), was = buttons;
    for (int i = 0; i < 64; i++) {
        uint64_t m = 1ull << i;
        if ((bits & m) && !(was & m)) press_ms[i] = now;
        if (!(bits & m) && (was & m) && now - press_ms[i] < MIN_PRESS_MS) {  // (a tap: held a little longer)
            if (now >= short_until) short_bits = 0;
            short_bits |= m;
            if (press_ms[i] + MIN_PRESS_MS > short_until) short_until = press_ms[i] + MIN_PRESS_MS;
        }
    }
    buttons = bits;
    if (!stick) { stick_x = stick_y = 0; return; }
    float vx = (stick_kx - stick_bx) / STICK_R, vy = (stick_by - stick_ky) / STICK_R;  // (y up)
    float m = sqrtf(vx * vx + vy * vy);
    if (m > 1) vx /= m, vy /= m;
    stick_x = (int32_t)lroundf(vx * 32767), stick_y = (int32_t)lroundf(vy * 32767);
}

void touch_reset(void) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_FINGERS; i++) fingers[i].role = ROLE_NONE, fingers[i].id = 0;
    publish_locked();
    pthread_mutex_unlock(&lock);
    look_mx = look_my = 0;
}

void touch_other_input(void) {
    if (!enabled() || hidden) return;
    hidden = true;
    touch_reset();
}

static Finger *finger(SDL_FingerID id, bool add) {
    for (int i = 0; i < MAX_FINGERS; i++)
        if (fingers[i].role != ROLE_NONE && fingers[i].id == id) return &fingers[i];
    if (!add) return NULL;
    for (int i = 0; i < MAX_FINGERS; i++)
        if (fingers[i].role == ROLE_NONE) { fingers[i].id = id; return &fingers[i]; }
    return NULL;
}

// What a finger landing here does: the nearest button within reach, else the stick or the camera
static int hit(float x, float y) {
    Btn b[TOUCH_MAX_BUTTONS];
    int n = layout(aspect, b), best = -1;
    float bd = 0;
    for (int i = 0; i < n; i++) {
        float dx = x - b[i].x, dy = y - b[i].y, d = sqrtf(dx * dx + dy * dy) / (b[i].r * HIT_SLACK);
        if (d <= 1 && (best < 0 || d < bd)) best = i, bd = d;
    }
    if (best >= 0) return ROLE_BUTTON + best;
    if (x < aspect * STICK_ZONE_X && y > STICK_ZONE_Y) return ROLE_STICK;
    return ROLE_LOOK;
}

static bool touch_mouse(const SDL_Event *e) {
    switch (e->type) {
    case SDL_EVENT_MOUSE_MOTION: return e->motion.which == SDL_TOUCH_MOUSEID;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP: return e->button.which == SDL_TOUCH_MOUSEID;
    case SDL_EVENT_MOUSE_WHEEL: return e->wheel.which == SDL_TOUCH_MOUSEID;
    default: return false;
    }
}

bool touch_event(const SDL_Event *e) {
    static bool was;  // (turned off with fingers down: nothing stays held)
    if (!enabled()) {
        if (was) touch_reset();
        was = false;
        return false;
    }
    was = true;
    if (touch_mouse(e)) return true;  // (the touch is the controls', not a mouse's)
    if (e->type != SDL_EVENT_FINGER_DOWN && e->type != SDL_EVENT_FINGER_MOTION && e->type != SDL_EVENT_FINGER_UP &&
        e->type != SDL_EVENT_FINGER_CANCELED)
        return false;
    if (e->tfinger.touchID == SDL_MOUSE_TOUCHID) return false;  // (a mouse SDL turned into a touch)
    SDL_Window *w = SDL_GetWindowFromID(e->tfinger.windowID);
    int ww = 0, wh = 0;
    if (w && SDL_GetWindowSize(w, &ww, &wh) && ww > 0 && wh > 0) aspect = (float)ww / wh;
    float x = e->tfinger.x * aspect, y = e->tfinger.y;
    static int nlog;  // (the first touches: where they land and what they do)
    if (nlog < 40 && e->type != SDL_EVENT_FINGER_MOTION && ++nlog)
        LOG("[touch] %s finger %llu at %.3f,%.3f (window %dx%d)\n", e->type == SDL_EVENT_FINGER_DOWN ? "down" : "up",
            (unsigned long long)e->tfinger.fingerID, x, y, ww, wh);
    pthread_mutex_lock(&lock);
    if (e->type == SDL_EVENT_FINGER_DOWN) {
        hidden = false;
        Finger *f = finger(e->tfinger.fingerID, true);
        if (f) {
            f->role = hit(x, y), f->x = x, f->y = y;
            if (f->role == ROLE_STICK) {  // (a base that fits on the screen)
                float m = STICK_R * 1.1f;
                stick_bx = x < m ? m : x, stick_by = y > 1 - m ? 1 - m : y;
                stick_kx = x, stick_ky = y;
            }
        }
    } else if (e->type == SDL_EVENT_FINGER_MOTION) {
        Finger *f = finger(e->tfinger.fingerID, false);
        if (f && f->role == ROLE_LOOK) {
            look_mx += llround((x - f->x) * LOOK_DEG * 1000);
            look_my += llround((y - f->y) * LOOK_DEG * 1000);
        } else if (f && f->role == ROLE_STICK) {
            stick_kx = x, stick_ky = y;
            float dx = x - stick_bx, dy = y - stick_by, d = sqrtf(dx * dx + dy * dy);
            if (d > STICK_R) stick_bx = x - dx * STICK_R / d, stick_by = y - dy * STICK_R / d;  // (the base follows)
        }
        if (f) f->x = x, f->y = y;
    } else {
        Finger *f = finger(e->tfinger.fingerID, false);
        if (f) f->role = ROLE_NONE, f->id = 0;
    }
    publish_locked();
    pthread_mutex_unlock(&lock);
    return true;
}

// Double tap: a tap is a finger down and up within TAP_MS, moved less than TAP_MOVE (screen heights); the second
// must start within DTAP_MS of the first's lift and land within DTAP_DIST of it. One finger at a time (a second
// finger down meanwhile is no tap). With the touch controls on, a tap that starts on a button or in the stick's part
// is the controls' (double-tapping A to jump twice opens nothing).
#define TAP_MS 250
#define TAP_MOVE 0.04f
#define DTAP_MS 350
#define DTAP_DIST 0.12f
bool touch_double_tap(const SDL_Event *e) {
    static SDL_FingerID id;
    static bool down, eligible;
    static float x0, y0, last_x, last_y;
    static uint64_t t0, last_up;
    static int fingers;
    if (e->type != SDL_EVENT_FINGER_DOWN && e->type != SDL_EVENT_FINGER_MOTION && e->type != SDL_EVENT_FINGER_UP &&
        e->type != SDL_EVENT_FINGER_CANCELED)
        return false;
    if (e->tfinger.touchID == SDL_MOUSE_TOUCHID) return false;
    SDL_Window *w = SDL_GetWindowFromID(e->tfinger.windowID);
    int ww = 0, wh = 0;
    float a = w && SDL_GetWindowSize(w, &ww, &wh) && ww > 0 && wh > 0 ? (float)ww / wh : aspect;
    float x = e->tfinger.x * a, y = e->tfinger.y;
    uint64_t now = SDL_GetTicks();
    if (e->type == SDL_EVENT_FINGER_DOWN) {
        fingers++;
        if (fingers > 1) { down = false, last_up = 0; return false; }
        int role = ROLE_LOOK;
        if (enabled()) {
            float sa = aspect;
            aspect = a;
            role = hit(x, y);
            aspect = sa;
        }
        id = e->tfinger.fingerID, down = true, eligible = role == ROLE_LOOK, x0 = x, y0 = y, t0 = now;
        return false;
    }
    if (e->type == SDL_EVENT_FINGER_MOTION) {
        if (down && e->tfinger.fingerID == id && hypotf(x - x0, y - y0) > TAP_MOVE) eligible = false;
        return false;
    }
    if (fingers > 0) fingers--;
    if (!down || e->tfinger.fingerID != id) return false;
    down = false;
    bool tap = e->type == SDL_EVENT_FINGER_UP && eligible && now - t0 <= TAP_MS && hypotf(x - x0, y - y0) <= TAP_MOVE;
    if (!tap) { last_up = 0; return false; }
    if (last_up && t0 - last_up <= DTAP_MS && hypotf(x0 - last_x, y0 - last_y) <= DTAP_DIST) {
        last_up = 0;
        LOG("[touch] double tap at %.3f,%.3f: settings\n", x, y);
        return true;
    }
    last_up = now, last_x = x, last_y = y;
    return false;
}

uint64_t touch_buttons(void) {
    if (!touch_active()) return 0;
    return buttons | (SDL_GetTicks() < short_until ? short_bits : 0);
}

void touch_stick(int32_t *x, int32_t *y) {
    bool on = touch_active();
    *x = on ? stick_x : 0, *y = on ? stick_y : 0;
}

void touch_take_look(double *dx, double *dy) {
    int64_t mx = atomic_exchange(&look_mx, 0), my = atomic_exchange(&look_my, 0);
    bool on = touch_active();
    *dx = on ? mx / 1000.0 : 0, *dy = on ? my / 1000.0 : 0;
}

bool touch_view(float a, TouchView *v) {
    if (!touch_active() || !(a > 0)) return false;
    Btn b[TOUCH_MAX_BUTTONS];
    pthread_mutex_lock(&lock);
    v->nbuttons = layout(a, b);
    uint64_t held = touch_buttons();
    for (int i = 0; i < v->nbuttons; i++)
        v->buttons[i] = (TouchButtonView){b[i].button, b[i].label, b[i].x, b[i].y, b[i].r, (held >> b[i].button & 1) != 0};
    v->stick_held = false;
    for (int i = 0; i < MAX_FINGERS; i++)
        if (fingers[i].role == ROLE_STICK) v->stick_held = true;
    v->stick_r = STICK_R;
    if (v->stick_held) {
        float k = a / aspect;  // (the overlay's aspect and the last touch's: the same window, but to be safe)
        v->stick_x = stick_bx * k, v->stick_y = stick_by;
        float kx = stick_kx - stick_bx, ky = stick_ky - stick_by, d = sqrtf(kx * kx + ky * ky);
        if (d > STICK_R) kx *= STICK_R / d, ky *= STICK_R / d;
        v->knob_x = v->stick_x + kx, v->knob_y = v->stick_y + ky;
    } else {
        v->stick_x = v->knob_x = 0.26f, v->stick_y = v->knob_y = 0.70f;  // (where it rests, drawn faint)
    }
    pthread_mutex_unlock(&lock);
    return true;
}
