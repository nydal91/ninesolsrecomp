// C++ exceptions: the landing (runtime/cpu.h RtEhFrame, tools/gen.py). The guest's own libunwind runs as
// recompiled code: it reads the guest stack and .eh_frame, finds the handler, runs the personality routines, and
// ends in __libunwind_Registers_arm64_jumpto(Registers_arm64 *) with the landing pad's registers. That function is
// replaced by this one (gen.py is_unwind_jumpto): load those registers, then longjmp to the C frame of the guest
// function the landing pad belongs to, which calls the pad's function (each pad is a function entry) and returns.
//   Registers_arm64: x0-x29 at 0x00, lr 0xF0, sp 0xF8, pc 0x100, d0-d31 0x110
#include <setjmp.h>
#include <stdlib.h>

#include "../hle.h"

static uint64_t g_landings;  // (stats)

void hle_rt_unwind_jumpto(Cpu *c) {
    uint64_t r = c->x[0];
    uint64_t pc = LD64(r + 0x100), sp = LD64(r + 0xF8);
    // the innermost recorded frame of the guest function holding pc that is the one at sp: a frame entered at
    // the function's start had sp = its CFA, above the body's sp; one entered later (a piece after a split) has
    // the body's sp. (A recursive call of the same function from the landing frame was entered at sp itself.)
    RtEhFrame *f = c->eh_top;
    for (; f; f = f->prev)
        if (f->lo <= pc && pc < f->hi && (f->start ? f->sp > sp : f->sp >= sp)) break;
    if (!f) {
        LOG("[eh] no frame for landing pad %llx (sp %llx); recorded frames:\n", (unsigned long long)pc,
            (unsigned long long)sp);
        for (RtEhFrame *g = c->eh_top; g; g = g->prev)
            LOG("[eh]   %llx-%llx sp %llx%s\n", (unsigned long long)g->lo, (unsigned long long)g->hi,
                (unsigned long long)g->sp, g->start ? " (at start)" : "");
        FATAL("[eh] can't land at %llx\n", (unsigned long long)pc);
        return;
    }
    if (g_landings++ < 4 || getenv("SAVAGEWIND_LOG_EH"))
        LOG("[eh] landing at %llx (sp %llx, frame %llx-%llx)\n", (unsigned long long)pc, (unsigned long long)sp,
            (unsigned long long)f->lo, (unsigned long long)f->hi);
    for (int i = 2; i <= 29; i++)
        if (i != 16 && i != 17) c->x[i] = LD64(r + 8 * i);  // (jumpto leaves x16 / x17 as they are)
    c->x[30] = pc;
    for (int i = 0; i < 32; i++) c->v[i] = LD64(r + 0x110 + 8 * i);  // (ldp d: the upper half zeroed)
    c->x[16] = sp;
    c->x[0] = LD64(r);
    c->x[1] = LD64(r + 8);
    c->sp = sp;
    c->pc = pc;
    c->eh_top = f->prev;
    _longjmp(f->jb, 1);
}
