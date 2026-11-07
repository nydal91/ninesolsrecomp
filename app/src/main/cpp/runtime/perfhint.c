// (Android) CPU clocks for the game's threads: an ADPF performance hint session plus the faster cores.
//
// MvDK's frame work is spread over many guest threads at 15-25 % each, so no core looks busy and the schedutil
// governor keeps the clusters low (A715s at 1.4 of 2.8 GHz on an SM8550): the game's own CPU time per frame then
// ran 13-16 ms, frames of 18-28 ms every second or so, and the game paced itself down to 30 fps for a moment each
// time. With the big clusters' minimum raised by hand the same level held 60 fps (5 frames over 18 ms in a minute,
// against 280). The non-root way: Android's performance hint API (API 33; looked up at run time, minSdk is 28)
// with each frame's work time against a 16.7 ms target, which the governor answers with clocks for those threads,
// and the threads kept off the little cores (sched_setaffinity on our own threads).
//
// perfhint_thread() registers the calling thread (guest threads, the recorder; the presenting thread registers
// itself at its first frame); perfhint_frame() reports one frame. SAVAGEWIND_PERFHINT=0: neither (affinity too).
#ifdef __ANDROID__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE  // (cpu_set_t, sched_setaffinity)
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include <stdbool.h>
#include "rt.h"

typedef struct APerformanceHintManager APerformanceHintManager;
typedef struct APerformanceHintSession APerformanceHintSession;
static APerformanceHintManager *(*p_get_manager)(void);
static APerformanceHintSession *(*p_create)(APerformanceHintManager *, const int32_t *, size_t, int64_t);
static int (*p_report)(APerformanceHintSession *, int64_t);
static int (*p_set_threads)(APerformanceHintSession *, const int32_t *, size_t);  // (API 34)
static void (*p_close)(APerformanceHintSession *);

#define MAX_TIDS 64
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static int32_t tids[MAX_TIDS];
static int ntids;
static int dirty;
static int state = -1;  // -1 not set up, 0 off, 1 on
static cpu_set_t fast;  // the cores above the slowest cluster
static int nfast;
static APerformanceHintSession *session;

#define TARGET_NS 16666667ll

static void setup(void) {
    const char *e = getenv("SAVAGEWIND_PERFHINT");
    state = !(e && !atoi(e));
    if (!state) { LOG("[perf] performance hints off (SAVAGEWIND_PERFHINT=0)\n"); return; }
    // the fast cores: those whose maximum clock is above the lowest one's (SM8550: 3-7 of 0-7)
    long maxf[CPU_SETSIZE] = {0}, lo = 0;
    int ncpu = (int)sysconf(_SC_NPROCESSORS_CONF);
    if (ncpu > CPU_SETSIZE) ncpu = CPU_SETSIZE;
    for (int i = 0; i < ncpu; i++) {
        char p[96];
        snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE *f = fopen(p, "r");
        if (f) { if (fscanf(f, "%ld", &maxf[i]) != 1) maxf[i] = 0; fclose(f); }
        if (maxf[i] && (!lo || maxf[i] < lo)) lo = maxf[i];
    }
    CPU_ZERO(&fast);
    for (int i = 0; i < ncpu; i++) if (maxf[i] > lo) { CPU_SET(i, &fast); nfast++; }
    void *lib = dlopen("libandroid.so", RTLD_NOW);
    if (lib) {
        p_get_manager = (APerformanceHintManager * (*)(void)) dlsym(lib, "APerformanceHint_getManager");
        p_create = (APerformanceHintSession * (*)(APerformanceHintManager *, const int32_t *, size_t, int64_t))
            dlsym(lib, "APerformanceHint_createSession");
        p_report = (int (*)(APerformanceHintSession *, int64_t))dlsym(lib, "APerformanceHint_reportActualWorkDuration");
        p_set_threads = (int (*)(APerformanceHintSession *, const int32_t *, size_t))dlsym(lib, "APerformanceHint_setThreads");
        p_close = (void (*)(APerformanceHintSession *))dlsym(lib, "APerformanceHint_closeSession");
    }
    LOG("[perf] fast cores: %d of %d; performance hint API: %s\n", nfast, ncpu,
        p_get_manager && p_create && p_report ? (p_set_threads ? "yes" : "yes (no setThreads)") : "no");
}

void perfhint_thread(void) {
    pthread_mutex_lock(&mu);
    if (state < 0) setup();
    if (state && nfast) sched_setaffinity(0, sizeof fast, &fast);
    if (state && ntids < MAX_TIDS) {
        int32_t tid = (int32_t)syscall(SYS_gettid);
        bool have = false;
        for (int i = 0; i < ntids; i++) have |= tids[i] == tid;
        if (!have) tids[ntids++] = tid, dirty = 1;
    }
    pthread_mutex_unlock(&mu);
}

// A guest thread that ended: off the session's list (a session naming a dead thread is refused by setThreads)
void perfhint_thread_end(void) {
    pthread_mutex_lock(&mu);
    int32_t tid = (int32_t)syscall(SYS_gettid);
    for (int i = 0; i < ntids; i++)
        if (tids[i] == tid) { tids[i] = tids[--ntids]; dirty = 1; break; }
    pthread_mutex_unlock(&mu);
}

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

// One frame presented; idle_ns: the time of it spent sleeping to pace (not work)
void perfhint_frame(uint64_t idle_ns) {
    static int64_t last;
    static bool self;
    if (!self) { self = true; perfhint_thread(); }
    if (!state) return;
    int64_t t = now_ns();
    int64_t dt = last ? t - last : 0;
    last = t;
    if (!p_get_manager || !p_create || !p_report) return;
    pthread_mutex_lock(&mu);
    if (dirty && ntids) {
        if (session && p_set_threads && p_set_threads(session, tids, (size_t)ntids) == 0) dirty = 0;
        else {
            if (session && p_close) p_close(session);
            APerformanceHintManager *m = p_get_manager();
            session = m ? p_create(m, tids, (size_t)ntids, TARGET_NS) : NULL;
            dirty = 0;
            static int logged;
            if (logged++ < 4) LOG("[perf] hint session %s for %d threads\n", session ? "created" : "refused", ntids);
        }
    }
    APerformanceHintSession *s = session;
    pthread_mutex_unlock(&mu);
    if (!s || dt <= 0) return;
    int64_t work = dt - (int64_t)idle_ns;
    if (work < 1000000) work = 1000000;
    if (work > 1000000000ll) return;  // (a pause: nothing to say)
    p_report(s, work);
}
#else
#include <stdint.h>
void perfhint_thread(void) {}
void perfhint_thread_end(void) {}
void perfhint_frame(uint64_t idle_ns) { (void)idle_ns; }
#endif
