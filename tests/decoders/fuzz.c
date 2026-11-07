/* Mutation fuzzer for the whole library (built-in WAV + native FLAC).
 * The input AND the workspace each sit against an unmapped guard page (alternating
 * which end), so any out-of-bounds read or write faults at once. A watchdog catches hangs.
 *   fuzz iterations seed1 [seed2 ...]      (seed files: WAV or FLAC) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include "peep.h"

static unsigned long long s = 88172645463325252ull;
static unsigned rnd(void){ s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (unsigned)(s >> 11); }
static void hang(int sig){ (void)sig; static const char m[] = "HANG\n"; if (write(2, m, sizeof m - 1)) {} _exit(99); }

/* n usable bytes with a PROT_NONE page on both sides; flush with the end or the start */
static unsigned char *guarded(size_t n, int end, void **base, size_t *tot)
{
    size_t pg = 4096, body = (n + pg - 1) & ~(pg - 1); *tot = body + 2 * pg;
    unsigned char *m = mmap(0, *tot, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(m, pg, PROT_NONE); mprotect(m + pg + body, pg, PROT_NONE);
    *base = m; return end ? m + pg + body - n : m + pg;
}

int main(int argc, char **argv)
{
    long iters = atol(argv[1]); int nseed = argc - 2;
    static unsigned char seed[8][1 << 17]; size_t sl[8];
    if (nseed > 8) nseed = 8;
    for (int i = 0; i < nseed; i++) { FILE *f = fopen(argv[2 + i], "rb"); sl[i] = fread(seed[i], 1, sizeof seed[i], f); fclose(f); }
    static const peep_codec *const codecs[] = { &peep_codec_flac, 0 };
    static int16_t out[4096 * 8 * 2];
    long opened = 0, played = 0; unsigned long long frames_out = 0;
    signal(SIGALRM, hang); if (getenv("FUZZSEED")) s ^= strtoull(getenv("FUZZSEED"), 0, 10) * 0x9E3779B97F4A7C15ull;
    for (long it = 0; it < iters; it++) {
        alarm(20);
        int si = rnd() % nseed; size_t n = sl[si];
        unsigned r = rnd() % 8;
        if (r == 0) n = rnd() % 200; else if (r == 1) n = n * (rnd() % 100) / 100;   /* truncations */
        void *ib, *wb = 0; size_t it_, wt = 0;
        unsigned char *b = guarded(n ? n : 1, rnd() & 1, &ib, &it_);
        memcpy(b, seed[si], n);
        int m = 1 + rnd() % 8;
        while (m-- && n) {
            size_t i = (rnd() % 3 == 0 && n > 64) ? rnd() % 64 : rnd() % n;           /* favour the headers */
            switch (rnd() % 6) {
              case 0: b[i] = rnd(); break;
              case 1: b[i] ^= 1 << (rnd() % 8); break;
              case 2: if (i + 4 <= n) { unsigned v[] = {0, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFF0, 1, 3, 0xFFFF, 0xFFF8FFF9}; memcpy(b + i, &v[rnd() % 9], 4); } break;
              case 3: if (i + 2 <= n) { b[i] = 0xFF; b[i + 1] = 0xF8 | (rnd() & 1); } break;   /* plant a sync code */
              case 4: if (n > 8) { size_t j = rnd() % n, k = 1 + rnd() % 64; if (j + k <= n && i + k <= n) memmove(b + i, b + j, k); } break;
              case 5: b[i] = 0; break;
            }
        }
        peep p; void *work = NULL; size_t ws = 0; unsigned char *w = NULL;
        int ok = peep_open(&p, codecs, b, n, NULL, 0);
        if (!ok && p.work_need && p.work_need <= (1u << 22)) {
            ws = p.work_need; w = guarded(ws, rnd() & 1, &wb, &wt); memset(w, rnd(), ws); work = w;
            ok = peep_open(&p, codecs, b, n, work, ws);
        }
        if (ok) {
            opened++; peep_set_gain(&p, rnd() % 300);
            for (int k = 0; k < 8; k++) {
                if (rnd() % 3 == 0) peep_seek(&p, ((unsigned long long)rnd() << (rnd() % 24)) % (p.total + 7));
                size_t want = 1 + rnd() % 4096, got = peep_fill(&p, out, want);
                if (got > want) { printf("peep_fill returned %zu > %zu\n", got, want); return 1; }
                frames_out += got; if (got) played++;
            }
            peep_close(&p);
        }
        munmap(ib, it_); if (w) munmap(wb, wt);
    }
    printf("fuzz: %ld inputs, %ld accepted, %ld fills produced audio (%llu frames), no crash\n", iters, opened, played, frames_out);
}
