/*
 * Peep test shim (LD_PRELOAD).
 *
 * Replaces ALSA with a model sound device, so the tests run without any
 * sound hardware and can measure exactly what a listener would hear:
 *
 *   - 44.1 kHz, a 100 ms buffer, consumed in real time (writes block when
 *     it is full, like a real device);
 *   - HEARD   file: every frame that is, or will be, heard, in order. A
 *                   drop (snd_pcm_drop) removes the not-yet-played frames;
 *   - PROGLOG file: "<ms> <frames heard so far>" every 2 ms, plus
 *                   "DROP <ms> <frames dropped> <stream length after>",
 *                   "REWIND <ms> <frames taken back> <stream length after>" (snd_pcm_rewind;
 *                   SIM_NO_REWIND=1 makes it refuse, as some sound systems do).
 *   - SIM_OPEN_MS: how long opening the device takes (default 0).
 *
 * It also logs every frame Peep uploads to the X server, and when it hides or
 * shows the pointer:
 *   - LATLOG file: "<ms> <checksum> <width>x<height>" per XPutImage, and
 *                  "CUR <ms> hide" / "CUR <ms> show" per XDefineCursor / XUndefineCursor.
 *
 * Times are CLOCK_MONOTONIC milliseconds, the same clock drive.c uses.
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <alsa/asoundlib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUF 4410   /* frames: 100 ms */
#define START 4408 /* start threshold: the buffer, in whole 1102-frame periods */

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void put(int fd, const char *s, int n)
{
    if (fd >= 0 && write(fd, s, n) < 0) { /* best effort */ }
}

/* ---- the model device ---------------------------------------------------- */
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static long heard_len = 0;  /* stream length: frames played + frames queued */
static long wr = 0;         /* frames queued since the last reset */
static double ts0 = 0;      /* when the device started playing, 0 = stopped */
static int heard_fd = -1, log_fd = -1;

static long queued(void) /* caller holds mu */
{
    if (!ts0) return wr;
    long left = wr - (long)((now() - ts0) * 44.1);
    return left < 0 ? 0 : left;
}

static void *logger(void *a)
{
    (void)a;
    for (;;) {
        usleep(2000);
        pthread_mutex_lock(&mu);
        long prog = heard_len - queued();
        pthread_mutex_unlock(&mu);
        char b[64];
        put(log_fd, b, snprintf(b, sizeof b, "%.3f %ld\n", now(), prog));
    }
    return 0;
}

int snd_pcm_open(snd_pcm_t **p, const char *n, snd_pcm_stream_t s, int m)
{
    const char *o = getenv("SIM_OPEN_MS"), *h = getenv("HEARD"), *l = getenv("PROGLOG");
    *p = (snd_pcm_t *)0x1;
    if (o) usleep(atoi(o) * 1000);
    if (h) heard_fd = open(h, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (l) {
        log_fd = open(l, O_CREAT | O_WRONLY | O_APPEND, 0644);
        pthread_t t;
        pthread_create(&t, 0, logger, 0);
    }
    return 0;
}

int snd_pcm_set_params(snd_pcm_t *p, snd_pcm_format_t f, snd_pcm_access_t a,
                       unsigned c, unsigned r, int soft, unsigned l)
{
    return 0;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *p, const void *b, snd_pcm_uframes_t n)
{
    for (;;) {
        pthread_mutex_lock(&mu);
        if (queued() + n <= BUF) {
            if (heard_fd >= 0 && pwrite(heard_fd, b, n * 4, heard_len * 4) < 0) { }
            heard_len += n;
            wr += n;
            if (!ts0 && wr >= START) ts0 = now();   /* like ALSA: starts at the start threshold */
            pthread_mutex_unlock(&mu);
            return n;
        }
        if (!ts0) ts0 = now();                      /* ...or when a write would block */
        pthread_mutex_unlock(&mu);
        usleep(1000);
    }
}

snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *p)
{
    pthread_mutex_lock(&mu);
    long r = BUF - queued();
    pthread_mutex_unlock(&mu);
    return r;
}

snd_pcm_state_t snd_pcm_state(snd_pcm_t *p) /* a prepared stream is not playing until it starts */
{
    pthread_mutex_lock(&mu);
    int r = ts0 ? 3 /* RUNNING */ : 2 /* PREPARED */;
    pthread_mutex_unlock(&mu);
    return r;
}

int snd_pcm_wait(snd_pcm_t *p, int ms)
{
    usleep(1000);
    return 1;
}

int snd_pcm_delay(snd_pcm_t *p, snd_pcm_sframes_t *d)
{
    pthread_mutex_lock(&mu);
    *d = queued();
    pthread_mutex_unlock(&mu);
    return 0;
}

snd_pcm_sframes_t snd_pcm_rewindable(snd_pcm_t *p)
{
    if (getenv("SIM_NO_REWIND")) return 0;
    pthread_mutex_lock(&mu);
    long r = ts0 ? queued() : 0;
    pthread_mutex_unlock(&mu);
    return r;
}

snd_pcm_sframes_t snd_pcm_rewind(snd_pcm_t *p, snd_pcm_uframes_t n)
{
    if (getenv("SIM_NO_REWIND")) return 0;
    pthread_mutex_lock(&mu);
    long q = queued();
    if ((long)n > q) n = q;
    heard_len -= n;
    wr -= n;
    if (heard_fd >= 0 && ftruncate(heard_fd, heard_len * 4) < 0) { }
    long after = heard_len;
    pthread_mutex_unlock(&mu);
    char b[96];
    put(log_fd, b, snprintf(b, sizeof b, "REWIND %.3f %ld %ld\n", now(), (long)n, after));
    return n;
}

int snd_pcm_drop(snd_pcm_t *p)
{
    pthread_mutex_lock(&mu);
    long x = queued();
    heard_len -= x;
    wr = 0;
    ts0 = 0;
    long after = heard_len;
    pthread_mutex_unlock(&mu);
    char b[96];
    put(log_fd, b, snprintf(b, sizeof b, "DROP %.3f %ld %ld\n", now(), x, after));
    return 0;
}

int snd_pcm_drain(snd_pcm_t *p)
{
    for (;;) {
        pthread_mutex_lock(&mu);
        long x = queued();
        pthread_mutex_unlock(&mu);
        if (!x) return 0;
        usleep(1000);
    }
}

int snd_pcm_prepare(snd_pcm_t *p) { return 0; }
int snd_pcm_recover(snd_pcm_t *p, int e, int s) { return 0; }
int snd_pcm_close(snd_pcm_t *p) { return 0; }

/* ---- frame checksums and pointer visibility -------------------------------------- */
static int lat_fd(void)
{
    static int fd = -2;
    if (fd == -2) {
        const char *l = getenv("LATLOG");
        fd = l ? open(l, O_CREAT | O_WRONLY | O_APPEND, 0644) : -1;
    }
    return fd;
}
int XDefineCursor(Display *d, Window w, Cursor c)
{
    static int (*real)(Display *, Window, Cursor);
    char s[48];
    if (!real) real = dlsym(RTLD_NEXT, "XDefineCursor");
    put(lat_fd(), s, snprintf(s, sizeof s, "CUR %.3f hide\n", now()));
    return real(d, w, c);
}
int XUndefineCursor(Display *d, Window w)
{
    static int (*real)(Display *, Window);
    char s[48];
    if (!real) real = dlsym(RTLD_NEXT, "XUndefineCursor");
    put(lat_fd(), s, snprintf(s, sizeof s, "CUR %.3f show\n", now()));
    return real(d, w);
}
int XPutImage(Display *d, Drawable w, GC g, XImage *i, int a, int b, int c, int e,
              unsigned W, unsigned H)
{
    static int (*real)(Display *, Drawable, GC, XImage *, int, int, int, int, unsigned, unsigned);
    int fd = lat_fd();
    if (!real) real = dlsym(RTLD_NEXT, "XPutImage");
    if (fd >= 0) {
        unsigned long h = 1469598103;
        unsigned *p = (unsigned *)i->data;
        for (unsigned k = 0; k < W * H; k++) h = (h ^ p[k]) * 1099511628211UL;
        char s[80];
        put(fd, s, snprintf(s, sizeof s, "%.3f %lx %ux%u\n", now(), h, W, H));
    }
    return real(d, w, g, i, a, b, c, e, W, H);
}
