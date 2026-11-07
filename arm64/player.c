/*
 * Peep ARM64 test player.
 *
 * A small, usable player whose only decoders are lib-Peep's: WAV and FLAC in
 * pure assembly (arm64/peep.s, arm64/flac.s). It exists to try those decoders
 * on real hardware. The rest of Peep is still x86-64 assembly, so this front
 * end is a stopgap written in C (X11 + ALSA); it is not part of Peep proper.
 *
 *   peep-a64 FILE_OR_FOLDER ...     play (folders are scanned for .wav/.flac)
 *   peep-a64 --bench FILE ...       no window, no sound: decode, print speed
 *                                   and a checksum of the decoded audio
 *
 * Keys: space pause, left/right seek 10 s, up/down volume, n/p next/previous,
 * q quit. Click the bar to seek, or use the buttons.
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <alsa/asoundlib.h>
#include <dirent.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "peep.h"

#define CHUNK 1024
#define WIN_W 480
#define WIN_H 206
#define NO_REQ (-1000000)

static const peep_codec *const codecs[] = {&peep_codec_flac, NULL};

/* ---- tracks -------------------------------------------------------------- */
static char **tracks;
static int ntracks, tcap;

static void add_track(const char *path)
{
    if (ntracks == tcap) tracks = realloc(tracks, (tcap = tcap ? tcap * 2 : 32) * sizeof *tracks);
    tracks[ntracks++] = strdup(path);
}
static int has_ext(const char *n)
{
    const char *d = strrchr(n, '.');
    return d && (!strcasecmp(d, ".wav") || !strcasecmp(d, ".flac"));
}
static void scan(const char *path)
{
    struct stat st;
    if (stat(path, &st)) return;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        struct dirent *e;
        if (!d) return;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.') continue;
            char full[4096];
            snprintf(full, sizeof full, "%s/%s", path, e->d_name);
            scan(full);
        }
        closedir(d);
    } else if (has_ext(path))
        add_track(path);
}
static int cmp_path(const void *a, const void *b) { return strcmp(*(char **)a, *(char **)b); }

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    uint8_t *b = n > 0 ? malloc(n) : NULL;
    if (b && fread(b, 1, n, f) != (size_t)n) { free(b); b = NULL; }
    fclose(f);
    *len = n;
    return b;
}
static long long now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

/* ---- state shared between the UI thread and the audio thread -------------- */
enum { ST_IDLE, ST_PLAYING, ST_FAILED, ST_FINISHED };
static atomic_int quit_flag, paused, gain_step = 20, req = NO_REQ, cur, state, audio_ok;
static atomic_long seek_rel, seek_abs = -1; /* seconds / per-mille of the track */
static atomic_ullong info_total, info_pos;
static atomic_uint info_rate, info_ch, info_kind;
static atomic_llong dec_ns, dec_frames; /* time spent inside peep_fill, frames made */
static unsigned gain_tab[21];

/* ---- the audio thread: owns the decoder, the file and the sound device ----- */
static peep P;
static uint8_t *file;
static void *work;
static int loaded, idx = -1;
static snd_pcm_t *pcm;
static unsigned pcm_rate;

static long queued_frames(void)
{
    snd_pcm_sframes_t d = 0;
    if (!pcm || snd_pcm_delay(pcm, &d) < 0 || d < 0) return 0;
    return d;
}
/* Drop what the device holds and decode again from the point actually heard:
 * sound stops at once (pause), a volume change is heard at once, a seek is exact. */
static void rewind_to_heard(void)
{
    uint64_t q = queued_frames(), pos = P.pos;
    if (pcm) { snd_pcm_drop(pcm); snd_pcm_prepare(pcm); }
    peep_seek(&P, pos - (q > pos ? pos : q));
}
static void unload(void)
{
    if (loaded) peep_close(&P);
    loaded = 0;
    free(file); file = NULL;
    free(work); work = NULL;
}
static void open_pcm(unsigned rate)
{
    if (pcm && pcm_rate == rate) return;
    if (pcm) { snd_pcm_close(pcm); pcm = NULL; pcm_rate = 0; }
    if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) { pcm = NULL; return; }
    if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED, 2, rate, 1,
                           100000) < 0) {
        snd_pcm_close(pcm);
        pcm = NULL;
        return;
    }
    pcm_rate = rate;
}
static int open_peep(const void *data, size_t len)
{
    size_t need = 0;
    memset(&P, 0, sizeof P);
    if (peep_open(&P, codecs, data, len, NULL, 0)) return 1;
    if (!(need = P.work_need)) return 0;
    if (!(work = calloc(1, need))) return 0;
    return peep_open(&P, codecs, data, len, work, need);
}
static void load_track(int i)
{
    size_t len = 0;
    if (pcm) { snd_pcm_drop(pcm); snd_pcm_prepare(pcm); } /* the old track stops at once */
    unload();
    idx = i;
    atomic_store(&cur, i);
    atomic_store(&info_pos, 0);
    atomic_store(&info_total, 0);
    file = read_file(tracks[i], &len);
    if (!file || !open_peep(file, len)) {
        unload();
        atomic_store(&state, ST_FAILED);
        if (i + 1 < ntracks) { usleep(600000); atomic_store(&req, i + 1); } /* skip what we can't play */
        return;
    }
    loaded = 1;
    atomic_store(&info_rate, P.rate);
    atomic_store(&info_ch, P.channels);
    atomic_store(&info_kind, P.kind);
    atomic_store(&info_total, P.total);
    open_pcm(P.rate);
    atomic_store(&audio_ok, pcm != NULL);
    peep_set_gain(&P, gain_tab[atomic_load(&gain_step)]);
    atomic_store(&state, ST_PLAYING);
}

static void *audio_main(void *arg)
{
    static int16_t buf[CHUNK * 2];
    int paused_done = 0, finished = 0;
    (void)arg;
    while (!atomic_load(&quit_flag)) {
        int r = atomic_exchange(&req, NO_REQ);
        if (r != NO_REQ) {
            if (r < 0) r = 0;
            if (r >= ntracks) r = ntracks - 1;
            if (r >= 0) { load_track(r); finished = 0; paused_done = 0; }
            continue;
        }
        if (!loaded) { usleep(20000); continue; }

        long rel = atomic_exchange(&seek_rel, 0), ab = atomic_exchange(&seek_abs, -1);
        if (rel || ab >= 0) {
            long long target = (long long)P.pos - (long long)queued_frames();
            if (ab >= 0) target = P.total ? (long long)((double)P.total * ab / 1000.0) : 0;
            target += rel * (long long)P.rate;
            if (target < 0) target = 0;
            if (P.total && target >= (long long)P.total) { /* past the end = next track */
                if (idx + 1 < ntracks) { atomic_store(&req, idx + 1); continue; }
                target = P.total - 1;
            }
            if (pcm) { snd_pcm_drop(pcm); snd_pcm_prepare(pcm); }
            peep_seek(&P, target);
            finished = 0;
            atomic_store(&state, ST_PLAYING);
        }
        if (atomic_load(&paused)) {
            if (!paused_done) { rewind_to_heard(); paused_done = 1; }
            atomic_store(&info_pos, P.pos);
            usleep(15000);
            continue;
        }
        paused_done = 0;
        if (finished) { usleep(20000); continue; }

        unsigned g = gain_tab[atomic_load(&gain_step)];
        if (g != P.gain) { rewind_to_heard(); peep_set_gain(&P, g); }

        long long t0 = now_ns();
        size_t n = peep_fill(&P, buf, CHUNK);
        atomic_fetch_add(&dec_ns, now_ns() - t0);
        atomic_fetch_add(&dec_frames, n);
        if (!n) { /* end of this track */
            if (pcm) { snd_pcm_drain(pcm); snd_pcm_prepare(pcm); }
            if (idx + 1 < ntracks) atomic_store(&req, idx + 1);
            else { finished = 1; atomic_store(&state, ST_FINISHED); atomic_store(&info_pos, P.total); }
            continue;
        }
        if (pcm) {
            int16_t *q = buf;
            size_t left = n;
            while (left) {
                snd_pcm_sframes_t w = snd_pcm_writei(pcm, q, left);
                if (w < 0) { if (snd_pcm_recover(pcm, (int)w, 1) < 0) break; continue; }
                q += w * 2;
                left -= w;
            }
        } else
            usleep((useconds_t)(n * 1000000ULL / P.rate)); /* no device: play silently in real time */
        long long heard = (long long)P.pos - (long long)queued_frames();
        atomic_store(&info_pos, heard < 0 ? 0 : heard);
    }
    unload();
    if (pcm) snd_pcm_close(pcm);
    return NULL;
}

/* ---- the window ---------------------------------------------------------------- */
static Display *dpy;
static Window win;
static Pixmap back;
static GC gc;
static XFontStruct *font;
static double load_pct = -1; /* decoder time as a share of the audio it produced */

enum { C_BG = 0x000000, C_TEXT = 0xF2F2F2, C_DIM = 0x8A8A8A, C_BAR = 0x303030, C_ACC = 0x4DA3FF,
       C_BTN = 0x1C1C1C, C_WARN = 0xFF8C5A };
static const char *btn_label[7] = {"Prev", "-10s", "Play", "+10s", "Next", "Vol-", "Vol+"};
#define BX(i) (16 + (i) * 64)
#define BY 150
#define BW 58
#define BH 26
#define BAR_X 16
#define BAR_Y 100
#define BAR_W (WIN_W - 32)
#define BAR_H 10

static void fill(int x, int y, int w, int h, unsigned long c)
{
    XSetForeground(dpy, gc, c);
    XFillRectangle(dpy, back, gc, x, y, w, h);
}
static void text(int x, int y, unsigned long c, const char *s)
{
    XSetForeground(dpy, gc, c);
    XDrawString(dpy, back, gc, x, y, s, strlen(s));
}
static int tw(const char *s) { return font ? XTextWidth(font, s, strlen(s)) : (int)strlen(s) * 6; }
static void fmt_time(char *o, unsigned long long sec)
{
    sprintf(o, "%llu:%02llu", sec / 60, sec % 60);
}

static void draw(void)
{
    char line[600], a[32], b[32];
    unsigned rate = atomic_load(&info_rate), ch = atomic_load(&info_ch), kind = atomic_load(&info_kind);
    unsigned long long total = atomic_load(&info_total), pos = atomic_load(&info_pos);
    int st = atomic_load(&state), i = atomic_load(&cur);
    fill(0, 0, WIN_W, WIN_H, C_BG);
    if (ntracks == 0) {
        text(16, 40, C_TEXT, "Peep ARM64 test player");
        text(16, 70, C_DIM, "Start it with a file or folder:   peep-a64 FILE_OR_FOLDER ...");
        goto done;
    }
    const char *base = strrchr(tracks[i], '/');
    base = base ? base + 1 : tracks[i];
    snprintf(line, sizeof line, "%d/%d  %.54s", i + 1, ntracks, base);
    text(16, 28, C_TEXT, line);
    if (st == ST_FAILED) text(16, 52, C_WARN, "cannot decode this file (lib-Peep handles WAV and FLAC)");
    else if (st == ST_IDLE) text(16, 52, C_DIM, "loading...");
    else {
        snprintf(line, sizeof line, "%s   %u Hz   %u ch   %s", kind == 1 ? "WAV" : "FLAC", rate, ch,
                 total ? (fmt_time(a, total / (rate ? rate : 1)), a) : "length unknown");
        text(16, 52, C_DIM, line);
    }
    snprintf(line, sizeof line, "decoder: lib-Peep ARM64 assembly%s",
             atomic_load(&audio_ok) || st != ST_PLAYING ? "" : "   (no sound device: silent)");
    text(16, 72, C_DIM, line);
    if (load_pct >= 0) {
        snprintf(line, sizeof line, "decoding uses %.2f%% of real time", load_pct);
        text(16, 88 - 2, C_DIM, line);
    }
    /* progress */
    fill(BAR_X, BAR_Y, BAR_W, BAR_H, C_BAR);
    if (total) {
        unsigned long long p = pos > total ? total : pos;
        fill(BAR_X, BAR_Y, (int)((double)BAR_W * p / total), BAR_H, C_TEXT);
    }
    fmt_time(a, rate ? pos / rate : 0);
    fmt_time(b, total && rate ? total / rate : 0);
    snprintf(line, sizeof line, "%s / %s", a, b);
    text(16, 128, C_TEXT, line);
    snprintf(line, sizeof line, "vol %d%%", atomic_load(&gain_step) * 5);
    text(WIN_W - 16 - tw(line), 128, C_DIM, line);
    /* buttons */
    for (int k = 0; k < 7; k++) {
        const char *l = k == 2 && !atomic_load(&paused) ? "Pause" : k == 2 ? "Play" : btn_label[k];
        fill(BX(k), BY, BW, BH, C_BTN);
        XSetForeground(dpy, gc, k == 2 ? C_ACC : C_DIM);
        XDrawRectangle(dpy, back, gc, BX(k), BY, BW - 1, BH - 1);
        text(BX(k) + (BW - tw(l)) / 2, BY + 17, k == 2 ? C_ACC : C_TEXT, l);
    }
    text(16, 198, C_DIM, "space pause   arrows seek/volume   n/p track   q quit");
done:
    XCopyArea(dpy, back, win, gc, 0, 0, WIN_W, WIN_H, 0, 0);
    XFlush(dpy);
}

static void next_track(int d)
{
    int t = atomic_load(&cur) + d;
    if (t >= 0 && t < ntracks) atomic_store(&req, t);
}
static void act(int k)
{
    switch (k) {
    case 0: /* previous: restart if more than 3 s in, else the one before */
        if (atomic_load(&info_pos) > 3ull * (atomic_load(&info_rate) ?: 1)) atomic_store(&seek_abs, 0);
        else next_track(-1);
        break;
    case 1: atomic_fetch_sub(&seek_rel, 10); break;
    case 2: atomic_store(&paused, !atomic_load(&paused)); break;
    case 3: atomic_fetch_add(&seek_rel, 10); break;
    case 4: next_track(1); break;
    case 5: if (atomic_load(&gain_step) > 0) atomic_fetch_sub(&gain_step, 1); break;
    case 6: if (atomic_load(&gain_step) < 20) atomic_fetch_add(&gain_step, 1); break;
    }
}
static void on_key(KeySym ks)
{
    switch (ks) {
    case XK_space: act(2); break;
    case XK_Left: act(1); break;
    case XK_Right: act(3); break;
    case XK_Up: act(6); break;
    case XK_Down: act(5); break;
    case XK_n: case XK_Next: act(4); break;
    case XK_p: case XK_Prior: act(0); break;
    case XK_q: case XK_Escape: atomic_store(&quit_flag, 1); break;
    }
}
static void on_click(int x, int y)
{
    if (ntracks == 0) return;
    if (y >= BAR_Y - 6 && y <= BAR_Y + BAR_H + 6 && x >= BAR_X && x <= BAR_X + BAR_W)
        atomic_store(&seek_abs, (long)(x - BAR_X) * 1000 / BAR_W);
    for (int k = 0; k < 7; k++)
        if (x >= BX(k) && x < BX(k) + BW && y >= BY && y < BY + BH) act(k);
}

static void update_load(void)
{
    static long long t0, n0, f0;
    long long t = now_ns(), n = atomic_load(&dec_ns), f = atomic_load(&dec_frames);
    unsigned rate = atomic_load(&info_rate);
    if (t - t0 < 1000000000LL) return;
    if (t0 && rate && f > f0) load_pct = 100.0 * (n - n0) / ((double)(f - f0) / rate * 1e9);
    t0 = t; n0 = n; f0 = f;
}

static int gui(void)
{
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fputs("peep-a64: cannot open the X display (use --bench without one)\n", stderr); return 1; }
    int scr = DefaultScreen(dpy);
    win = XCreateSimpleWindow(dpy, RootWindow(dpy, scr), 0, 0, WIN_W, WIN_H, 0, 0, 0);
    XStoreName(dpy, win, "Peep ARM64 (lib-Peep decoders)");
    XSizeHints sh = {.flags = PMinSize | PMaxSize, .min_width = WIN_W, .max_width = WIN_W,
                     .min_height = WIN_H, .max_height = WIN_H};
    XSetWMNormalHints(dpy, win, &sh);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | ButtonPressMask);
    Atom del = XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
    XSetWMProtocols(dpy, win, &del, 1);
    gc = XCreateGC(dpy, win, 0, NULL);
    back = XCreatePixmap(dpy, win, WIN_W, WIN_H, DefaultDepth(dpy, scr));
    if ((font = XLoadQueryFont(dpy, "-misc-fixed-medium-r-normal--14-*-*-*-*-*-*-*")) ||
        (font = XLoadQueryFont(dpy, "fixed")))
        XSetFont(dpy, gc, font->fid);
    XMapWindow(dpy, win);

    pthread_t th;
    if (ntracks) atomic_store(&req, 0);
    pthread_create(&th, NULL, audio_main, NULL);
    struct pollfd pf = {.fd = ConnectionNumber(dpy), .events = POLLIN};
    while (!atomic_load(&quit_flag)) {
        while (XPending(dpy)) {
            XEvent e;
            XNextEvent(dpy, &e);
            if (e.type == KeyPress) on_key(XLookupKeysym(&e.xkey, 0));
            else if (e.type == ButtonPress && e.xbutton.button == 1) on_click(e.xbutton.x, e.xbutton.y);
            else if (e.type == ClientMessage && (Atom)e.xclient.data.l[0] == del) atomic_store(&quit_flag, 1);
        }
        update_load();
        draw();
        poll(&pf, 1, 200);
    }
    pthread_join(th, NULL);
    return 0;
}

/* ---- --bench: decode only, with a checksum ----------------------------------------- */
static int bench(int argc, char **argv)
{
    int bad = 0;
    for (int i = 0; i < argc; i++) {
        size_t len = 0;
        uint8_t *f = read_file(argv[i], &len);
        if (!f || !open_peep(f, len)) { printf("%s: cannot decode\n", argv[i]); bad = 1; free(f); free(work); work = NULL; continue; }
        static int16_t out[4096 * 2];
        unsigned long long frames = 0, h = 0xcbf29ce484222325ull;
        long long t0 = now_ns();
        size_t n;
        while ((n = peep_fill(&P, out, 4096))) {
            const uint8_t *b = (const uint8_t *)out;
            for (size_t k = 0; k < n * 4; k++) h = (h ^ b[k]) * 0x100000001b3ull;
            frames += n;
        }
        double secs = (now_ns() - t0) / 1e9, audio = (double)frames / (P.rate ? P.rate : 1);
        printf("%s: %s %u Hz %u ch %llu frames  %.0fx realtime  checksum %016llx\n", argv[i],
               P.kind == 1 ? "WAV" : "FLAC", P.rate, P.channels, frames, secs > 0 ? audio / secs : 0.0, h);
        peep_close(&P);
        free(f); free(work); work = NULL;
    }
    return bad;
}

int main(int argc, char **argv)
{
    for (int i = 0; i <= 20; i++) gain_tab[i] = (unsigned)(256.0 * i * i / 400.0 + 0.5);
    if (argc > 1 && !strcmp(argv[1], "--bench")) return bench(argc - 2, argv + 2);
    for (int i = 1; i < argc; i++) {
        struct stat st;
        int start = ntracks;
        if (!stat(argv[i], &st) && !S_ISDIR(st.st_mode)) add_track(argv[i]);
        else { scan(argv[i]); qsort(tracks + start, ntracks - start, sizeof *tracks, cmp_path); }
    }
    return gui();
}
