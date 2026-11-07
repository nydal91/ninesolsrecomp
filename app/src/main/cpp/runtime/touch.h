// On-screen touch controls (Controls > Touch controls; runtime/touch.c): a Switch controller drawn over the game.
// The left part of the screen is a floating left stick, a drag anywhere else turns the camera, and the buttons are
// where a Switch's are. The overlay is drawn by runtime/ui/menu.mm (touch_overlay_draw).
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL_events.h>

#ifdef __cplusplus
extern "C" {
#endif

// main thread (the window loop): finger events; true when the event was the touch controls' (or a mouse event SDL
// made from a touch, which the game must not see as the mouse's while the touch controls are on)
bool touch_event(const SDL_Event *e);
void touch_reset(void);              // let go of everything (focus lost, setting turned off)
void touch_other_input(void);        // a controller or key was used: the overlay hides until the next touch

// main thread, before the menu routes the event (runtime/ui/menu.mm): true when this finger lift ends a double tap -
// two quick taps close together on free screen (not on a button or the stick's part while the touch controls are on;
// anywhere while they're off), which opens the settings menu
bool touch_double_tap(const SDL_Event *e);

bool touch_active(void);             // the setting is on and the overlay is shown
uint64_t touch_buttons(void);        // Switch button bits held (runtime/hle/input.c BTN_*)
void touch_stick(int32_t *x, int32_t *y);  // the left stick, -32767..32767 (y up)
void touch_take_look(double *dx_deg, double *dy_deg);  // the camera drag since the last call, degrees (y down)

// What the overlay draws, in units of the screen's height (x from 0 to aspect, y from 0 at the top to 1)
enum { TOUCH_MAX_BUTTONS = 20 };
typedef struct {
    int button;         // BTN_* bit
    const char *label;
    float x, y, r;      // centre and radius
    bool held;
} TouchButtonView;
typedef struct {
    int nbuttons;
    TouchButtonView buttons[TOUCH_MAX_BUTTONS];
    float stick_x, stick_y, stick_r;  // the stick's base
    float knob_x, knob_y;             // its knob
    bool stick_held;
} TouchView;
bool touch_view(float aspect, TouchView *out);  // false: nothing to draw

#ifdef __cplusplus
}
#endif
