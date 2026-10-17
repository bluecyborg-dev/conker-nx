/*
 * Sampling profiler for the Linux bench (RECOMP_LINUX_PROFILE=1).
 *
 * The console's profiler (switch_nx.c) needs Horizon's thread syscalls, and
 * the bench container has no perf. So: an ITIMER_PROF timer raises SIGPROF
 * every millisecond of process CPU time, the handler records the interrupted
 * thread's id and pc, and a reporter thread prints each window in the
 * console's "[profile]" format -- per thread (slot = Linux tid), the hottest
 * 128-byte code granules as offsets into the executable --
 * so tools/prof_log_report.py resolves both (with --window-s 1 here).
 *
 * RECOMP_LINUX_PROFILE_WINDOW_MS sets the window (default 1000): short
 * enough to separate a one-second stall from the frames around it.
 */
#if defined(__linux__) && !defined(__SWITCH__)

#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>

extern char __executable_start[];

#define LPROF_RING (1u << 18)
#define LPROF_TOP 40
static struct { uint32_t tid, off; uintptr_t pc; } s_ring[LPROF_RING];
static volatile uint32_t s_head;
static uint32_t s_tail;

static void on_sigprof(int sig, siginfo_t *si, void *uc_)
{
    ucontext_t *uc = (ucontext_t *)uc_;
    uintptr_t pc;
    uint32_t i;
    (void)sig; (void)si;
#if defined(__aarch64__)
    pc = (uintptr_t)uc->uc_mcontext.pc;
#elif defined(__x86_64__)
    pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#else
    pc = 0;
#endif
    i = __atomic_fetch_add(&s_head, 1, __ATOMIC_RELAXED);
    s_ring[i & (LPROF_RING - 1)].tid = (uint32_t)syscall(SYS_gettid);
    s_ring[i & (LPROF_RING - 1)].pc = pc;
    s_ring[i & (LPROF_RING - 1)].off = pc >= (uintptr_t)__executable_start
        && pc - (uintptr_t)__executable_start < 0xFFFFFFFFu
        ? (uint32_t)(pc - (uintptr_t)__executable_start) : 0xFFFFFFFFu;
}

static int key_cmp(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* Samples outside the executable (libc, the Vulkan driver), by symbol:
 * "[profile-lib] slot T: name:count ...". dladdr is not async-signal-safe,
 * so it runs here, on the reporter thread, not in the handler. */
static void report_libs(uint32_t from, uint32_t to)
{
    enum { MAXN = 64 };
    struct { uint32_t tid; const void *sym; const char *name; uint32_t c; } agg[MAXN];
    uint32_t na = 0, i, k;
    for (i = from; i != to; i++) {
        uint32_t j = i & (LPROF_RING - 1);
        Dl_info di;
        const void *sym = NULL;
        const char *name = "?";
        if (s_ring[j].off != 0xFFFFFFFFu)
            continue;
        if (dladdr((void *)s_ring[j].pc, &di)) {
            sym = di.dli_saddr ? di.dli_saddr : di.dli_fbase;
            name = di.dli_sname ? di.dli_sname : di.dli_fname;
        }
        for (k = 0; k < na; k++)
            if (agg[k].tid == s_ring[j].tid && agg[k].sym == sym)
                break;
        if (k == na) {
            if (na == MAXN)
                continue;
            agg[na].tid = s_ring[j].tid; agg[na].sym = sym; agg[na].name = name; agg[na].c = 0;
            na++;
        }
        agg[k].c++;
    }
    for (k = 0; k < na; k++)
        if (agg[k].c >= 2)
            fprintf(stderr, "[profile-lib] slot %u: %s:%u\n", agg[k].tid, agg[k].name, agg[k].c);
}

static void report(void)
{
    static uint64_t keys[LPROF_RING];
    struct { uint32_t g, c; } top[LPROF_TOP];
    uint32_t head = __atomic_load_n(&s_head, __ATOMIC_ACQUIRE), n = 0, i, k;
    if (head - s_tail > LPROF_RING)
        s_tail = head - LPROF_RING;
    report_libs(s_tail, head);
    for (; s_tail != head; s_tail++) {
        uint32_t j = s_tail & (LPROF_RING - 1);
        keys[n++] = ((uint64_t)s_ring[j].tid << 32) | (s_ring[j].off & ~127u);
    }
    qsort(keys, n, sizeof keys[0], key_cmp);
    for (i = 0; i < n;) {
        uint32_t tid = (uint32_t)(keys[i] >> 32), j = i, nt = 0, t;
        char line[LPROF_TOP * 16 + 64];
        int len;
        while (j < n && (uint32_t)(keys[j] >> 32) == tid) {
            uint32_t e = j, c;
            while (e < n && keys[e] == keys[j])
                e++;
            c = e - j;
            for (t = nt < LPROF_TOP ? nt++ : LPROF_TOP; t > 0 && top[t - 1].c < c; t--)
                if (t < LPROF_TOP)
                    top[t] = top[t - 1];
            if (t < LPROF_TOP) {
                top[t].g = (uint32_t)keys[j];
                top[t].c = c;
            }
            j = e;
        }
        len = snprintf(line, sizeof line, "[profile] slot %u n %u:", tid, j - i);
        for (k = 0; k < nt && len < (int)sizeof line - 16; k++)
            len += snprintf(line + len, sizeof line - len, " %x:%u", top[k].g, top[k].c);
        fprintf(stderr, "%s\n", line);
        i = j;
    }
}

static void *reporter(void *arg)
{
    unsigned ms = (unsigned)(uintptr_t)arg;
    for (;;) {
        usleep(ms * 1000u);
        report();
    }
    return NULL;
}

void linux_prof_start(void)
{
    const char *e = getenv("RECOMP_LINUX_PROFILE");
    const char *w = getenv("RECOMP_LINUX_PROFILE_WINDOW_MS");
    unsigned ms = w && atoi(w) > 0 ? (unsigned)atoi(w) : 1000u;
    struct sigaction sa;
    struct itimerval it;
    pthread_t t;
    if (!e || *e != '1')
        return;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sigprof;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, NULL);
    it.it_interval.tv_sec = 0;
    it.it_interval.tv_usec = 1000;
    it.it_value = it.it_interval;
    setitimer(ITIMER_PROF, &it, NULL);
    if (pthread_create(&t, NULL, reporter, (void *)(uintptr_t)ms) == 0)
        pthread_detach(t);
    fprintf(stderr, "[prof] Linux sampler: 1 kHz of process CPU time, %u ms windows\n", ms);
}

#else
void linux_prof_start(void) { }
#endif
