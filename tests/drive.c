/*
 * Peep test driver.
 *
 * Acts as the user (key presses, pointer movement) and, where needed, as the
 * window manager. run.py starts Peep, runs one command and reads the
 * "name=value" lines it prints. Marks for the log files use CLOCK_MONOTONIC
 * milliseconds, like tests/shim.c.
 *
 *   drive sync                 resize with _NET_WM_SYNC_REQUEST, count acks
 *   drive hover                controls show/hide/fade, click vs drag
 *   drive latency              time from a seek key to the changed clock
 *   drive burst SEQ OUT.ppm    key burst (R, L, . = pause), then a screenshot
 *   drive pause plain|seek     pause/resume (optionally seeking while paused)
 *   drive tick                 how often the screen is redrawn
 *   drive version              press V, watch the notice appear and expire
 *   drive quit PID MODE        time from Q to exit, MODE = playing|paused|...
 *   drive idle SECONDS         wait, then quit
 *   drive which                is the cover on screen the playing track's?
 *   drive stress               skip tracks and toggle fullscreen rapidly
 */
#define _GNU_SOURCE
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/sync.h>
#include <X11/keysym.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static Display *d;
static Window w, R;

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static void ms(int m) { usleep(m * 1000); }

static void mark(const char *env, const char *prefix, const char *name)
{
    const char *path = getenv(env);
    if (!path) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "%s %.3f %s\n", prefix, now(), name);
    fclose(f);
}

static Window find(Window x)
{
    Window r, p, *k;
    unsigned n;
    char *nm;
    if (XFetchName(d, x, &nm) && nm) {
        int ok = !strncmp(nm, "Peep", 4);
        XFree(nm);
        if (ok) return x;
    }
    if (!XQueryTree(d, x, &r, &p, &k, &n)) return 0;
    for (unsigned i = 0; i < n; i++) {
        Window f = find(k[i]);
        if (f) return f;
    }
    return 0;
}

static void open_display(void)
{
    d = XOpenDisplay(0);
    if (!d) { puts("error=no display"); exit(2); }
    R = DefaultRootWindow(d);
}
static int viewable(void)
{
    XWindowAttributes a;
    return XGetWindowAttributes(d, w, &a) && a.map_state == IsViewable;
}
/* When we are the window manager (hover), map and resize requests are ours to
 * grant, as a real window manager would. */
static void wm_event(XEvent *e)
{
    if (e->type == MapRequest) XMapWindow(d, e->xmaprequest.window);
    else if (e->type == ConfigureRequest) {
        XConfigureRequestEvent *c = &e->xconfigurerequest;
        XWindowChanges ch = {.x = c->x, .y = c->y, .width = c->width, .height = c->height,
                             .border_width = c->border_width, .sibling = c->above,
                             .stack_mode = c->detail};
        XConfigureWindow(d, c->window, c->value_mask, &ch);
    }
}
/* Peep keeps its window unmapped for up to 0.3 s so that it can appear at the
 * cover's size. Wait for it to be on screen. */
static void wait_viewable(int as_wm)
{
    for (int i = 0; i < 600; i++) {
        while (as_wm && XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            wm_event(&e);
        }
        XSync(d, 0);
        if (viewable()) return;
        ms(50);
    }
    puts("error=Peep window never appeared");
    exit(1);
}
static void find_window(void)
{
    if (!d) open_display();
    for (int i = 0; i < 600 && !w; i++) {
        w = find(R);
        if (!w) ms(50);
    }
    if (!w) { puts("error=no Peep window"); exit(1); }
}
static void need_window(void)
{
    find_window();
    wait_viewable(0);
}

static void key(KeySym ks)
{
    XEvent e = {0};
    e.xkey.type = KeyPress;
    e.xkey.window = w;
    e.xkey.root = R;
    e.xkey.keycode = XKeysymToKeycode(d, ks);
    e.xkey.same_screen = 1;
    XSendEvent(d, w, 1, KeyPressMask, &e);
    XSync(d, 0);
}
static void warp(int x, int y)
{
    XWarpPointer(d, None, R, 0, 0, 0, 0, x, y);
    XSync(d, 0);
}
static void win_size(int *W, int *H)
{
    XWindowAttributes a;
    XGetWindowAttributes(d, w, &a);
    *W = a.width;
    *H = a.height;
}
static void inside(void) { int W, H; win_size(&W, &H); warp(W / 2, H / 2); }
static void outside(void) { warp(1500, 1100); }

static unsigned char *grab(int *W, int *H)
{
    win_size(W, H);
    XImage *im = XGetImage(d, w, 0, 0, *W, *H, AllPlanes, ZPixmap);
    unsigned char *b = malloc((size_t)*W * *H * 3);
    for (int y = 0; y < *H; y++)
        for (int x = 0; x < *W; x++) {
            unsigned long p = XGetPixel(im, x, y);
            unsigned char *q = b + ((size_t)y * *W + x) * 3;
            q[0] = p >> 16; q[1] = p >> 8; q[2] = p;
        }
    XDestroyImage(im);
    return b;
}
static void shot(const char *fn)
{
    int W, H;
    unsigned char *b = grab(&W, &H);
    FILE *o = fopen(fn, "wb");
    fprintf(o, "P6 %d %d 255\n", W, H);
    fwrite(b, 1, (size_t)W * H * 3, o);
    fclose(o);
    free(b);
}
static double diff(unsigned char *a, unsigned char *b, int n)
{
    double s = 0;
    for (int i = 0; i < n; i++) s += abs(a[i] - b[i]);
    return s / n;
}

/* ---- sync: _NET_WM_SYNC_REQUEST ------------------------------------------ */
static void cmd_sync(void)
{
    need_window();
    int a, b;
    XSyncQueryExtension(d, &a, &b);
    XSyncInitialize(d, &a, &b);
    Atom prot = XInternAtom(d, "WM_PROTOCOLS", 0), sr = XInternAtom(d, "_NET_WM_SYNC_REQUEST", 0),
         sc = XInternAtom(d, "_NET_WM_SYNC_REQUEST_COUNTER", 0);
    Atom *pr;
    int np, has = 0;
    XGetWMProtocols(d, w, &pr, &np);
    for (int i = 0; i < np; i++) if (pr[i] == sr) has = 1;
    printf("advertises_sync=%d\n", has);
    Atom t;
    int f;
    unsigned long n, af;
    unsigned char *data;
    XGetWindowProperty(d, w, sc, 0, 1, 0, XA_CARDINAL, &t, &f, &n, &af, &data);
    if (!n) { puts("acked=0\nerror=no counter"); return; }
    XSyncCounter c = *(unsigned long *)data;
    ms(1500);
    int ok = 0;
    double t0 = now();
    for (int k = 1; k <= 40; k++) {
        XEvent e = {0};
        e.xclient.type = ClientMessage;
        e.xclient.window = w;
        e.xclient.message_type = prot;
        e.xclient.format = 32;
        e.xclient.data.l[0] = sr;
        e.xclient.data.l[2] = k * 1000;
        XSendEvent(d, w, 0, 0, &e);
        XResizeWindow(d, w, 500 + k * 13, 500 + k * 13);
        XSync(d, 0);
        XSyncValue v;
        for (int i = 0; i < 400; i++) {
            XSyncQueryCounter(d, c, &v);
            if (XSyncValueLow32(v) == (unsigned)(k * 1000)) { ok++; break; }
            usleep(5000);
        }
    }
    printf("acked=%d\nms_per_step=%.1f\n", ok, (now() - t0) / 40);
}

/* ---- hover: show / hide / fade / drag ------------------------------------- */
static int count_moves(void)
{
    int n = 0;
    XEvent e;
    Atom mr = XInternAtom(d, "_NET_WM_MOVERESIZE", 0);
    while (XPending(d)) {
        XNextEvent(d, &e);
        if (e.type == ClientMessage && e.xclient.message_type == mr) n++;
        wm_event(&e);
    }
    return n;
}
static void click(int x, int y)
{
    XEvent e = {0};
    e.xbutton.type = ButtonPress;
    e.xbutton.window = w;
    e.xbutton.root = R;
    e.xbutton.x = x;
    e.xbutton.y = y;
    e.xbutton.x_root = x + 7;
    e.xbutton.y_root = y + 9;
    e.xbutton.button = 1;
    e.xbutton.same_screen = 1;
    XSendEvent(d, w, 1, ButtonPressMask, &e);
    XSync(d, 0);
}
static void cmd_hover(void)
{
    open_display();
    XSelectInput(d, R, SubstructureRedirectMask); /* we are the window manager */
    outside();
    find_window();
    wait_viewable(1);
    ms(1500);
    int W, H;
    unsigned char *bare = grab(&W, &H);
    int n = W * H * 3;
    key(XK_Tab);
    ms(200);
    unsigned char *f = grab(&W, &H);
    printf("outside_diff=%.2f\n", diff(f, bare, n));
    inside();
    ms(200);
    unsigned char *on = grab(&W, &H);
    double full = diff(on, bare, n);
    printf("inside_diff=%.2f\n", full);
    outside();
    int t[] = {100, 250, 400, 700}, el = 0;
    for (int i = 0; i < 4; i++) {
        ms(t[i] - el);
        el = t[i];
        f = grab(&W, &H);
        printf("fade_%d_pct=%.0f\n", t[i], 100 * diff(f, bare, n) / full);
    }
    inside();
    ms(200);
    count_moves();
    click(W / 2, H / 4); /* on the art: should start a window drag */
    ms(200);
    printf("art_click_moves=%d\n", count_moves());
    unsigned char *b4 = grab(&W, &H);
    click(W / 2, H * 3 / 4); /* on the play/pause button */
    ms(300);
    printf("button_click_moves=%d\n", count_moves());
    printf("button_changed_frame=%d\n", diff(b4, grab(&W, &H), n) > 0.01);
}

/* ---- latency: seek key -> changed clock ----------------------------------- */
static void cmd_latency(void)
{
    need_window();
    ms(1500);
    key(XK_space);
    ms(300);
    key(XK_Tab);
    inside();
    ms(600);
    for (int i = 0; i < 6; i++) {
        mark("LATLOG", "KEY", "");
        key(i % 2 ? XK_Left : XK_Right);
        ms(700);
    }
    key(XK_q);
}

/* ---- burst: keys, then a screenshot ---------------------------------------- */
static void cmd_burst(const char *seq, const char *out)
{
    need_window();
    ms(1200);
    key(XK_space);
    ms(300);
    key(XK_Tab);
    inside();
    ms(500);
    for (const char *p = seq; *p; p++) {
        if (*p == 'R') key(XK_Right);
        else if (*p == 'L') key(XK_Left);
        else ms(150);
        ms(4);
    }
    ms(900);
    shot(out);
    key(XK_q);
}

/* ---- pause ------------------------------------------------------------------ */
static void cmd_pause(const char *mode)
{
    need_window();
    int seek = !strcmp(mode, "seek");
    ms(1500);
    mark("PROGLOG", "MARK", "PAUSE");
    key(XK_space);
    ms(500);
    if (seek) { key(XK_Right); ms(300); }
    mark("PROGLOG", "MARK", "RESUME");
    key(XK_space);
    ms(1500);
    mark("PROGLOG", "MARK", "PAUSE2");
    key(XK_space);
    ms(500);
    mark("PROGLOG", "MARK", "RESUME2");
    key(XK_space);
    ms(1200);
    key(XK_q);
}

/* ---- tick: redraw cadence ---------------------------------------------------- */
static void cmd_tick(void)
{
    need_window();
    ms(1500);
    key(XK_Tab);
    inside();
    ms(500);
    mark("LATLOG", "MARK", "PLAY");
    sleep(6);
    mark("LATLOG", "MARK", "PAUSE");
    key(XK_space);
    ms(300);
    mark("LATLOG", "MARK", "PAUSED");
    sleep(4);
    mark("LATLOG", "MARK", "RESUME");
    key(XK_space);
    ms(300);
    mark("LATLOG", "MARK", "NOTICE");
    key(XK_f);
    sleep(7);
    mark("LATLOG", "MARK", "END");
    key(XK_q);
}

/* ---- version ------------------------------------------------------------------ */
static void cmd_version(void)
{
    need_window();
    ms(1500);
    mark("LATLOG", "MARK", "VKEY");
    key(XK_v);
    ms(500);
    if (getenv("SHOT")) shot(getenv("SHOT")); /* optional: look at the notice */
    ms(3000);
    mark("LATLOG", "MARK", "END");
    key(XK_q);
}

/* ---- quit -------------------------------------------------------------------- */
static void cmd_quit(int pid, const char *mode)
{
    need_window();
    ms(1500);
    if (!strcmp(mode, "paused")) { key(XK_space); ms(300); }
    if (!strcmp(mode, "seeking")) for (int i = 0; i < 6; i++) { key(XK_Right); ms(2); }
    if (!strcmp(mode, "skipping")) for (int i = 0; i < 4; i++) { key(XK_n); ms(2); }
    double t0 = now();
    key(XK_q);
    for (int i = 0; i < 4000; i++) {
        /* gone, or exited and waiting for its parent to collect it (zombie) */
        char f[64], b[512];
        snprintf(f, sizeof f, "/proc/%d/stat", pid);
        FILE *s = fopen(f, "r");
        if (!s) break;
        char *p = fgets(b, sizeof b, s) ? strrchr(b, ')') : 0;
        fclose(s);
        if (!p || p[2] == 'Z') break;
        usleep(500);
    }
    printf("quit_ms=%.1f\n", now() - t0);
}

static void cmd_idle(int secs)
{
    need_window();
    sleep(secs);
    key(XK_q);
}

/* ---- which: the cover matches the track -------------------------------------- */
static const char *colour(void)
{
    int W, H;
    win_size(&W, &H);
    XImage *im = XGetImage(d, w, W / 2, H / 2, 1, 1, AllPlanes, ZPixmap);
    unsigned long p = XGetPixel(im, 0, 0);
    XDestroyImage(im);
    int r = p >> 16 & 255, g = p >> 8 & 255, b = p & 255;
    return r > 150 ? "red" : g > 150 ? "green" : b > 150 ? "blue" : "other";
}
static void cmd_which(void)
{
    need_window();
    ms(300);
    printf("start=%s\n", colour());
    key(XK_n); ms(300); printf("after_n=%s\n", colour());
    key(XK_n); ms(300); printf("after_nn=%s\n", colour());
    key(XK_p); key(XK_p); ms(300); printf("after_pp=%s\n", colour());
    for (int i = 0; i < 6; i++) { key(XK_n); key(XK_p); }
    ms(400);
    printf("after_np6=%s\n", colour());
    key(XK_q);
}

/* ---- stress ------------------------------------------------------------------- */
static void cmd_stress(void)
{
    need_window();
    sleep(3);
    for (int i = 0; i < 40; i++) {
        key(i % 3 == 2 ? XK_p : XK_n);
        usleep(i < 20 ? 3000 : 60000);
    }
    key(XK_F11); sleep(1); key(XK_F11); sleep(1); key(XK_F11); sleep(1);
    key(XK_Escape); sleep(1);
    key(XK_q);
    puts("done=1");
}

int main(int argc, char **argv)
{
    setvbuf(stdout, 0, _IOLBF, 0);
    if (argc < 2) { fputs("usage: drive <command>\n", stderr); return 2; }
    const char *c = argv[1];
    if (!strcmp(c, "sync")) cmd_sync();
    else if (!strcmp(c, "hover")) cmd_hover();
    else if (!strcmp(c, "latency")) cmd_latency();
    else if (!strcmp(c, "burst") && argc > 3) cmd_burst(argv[2], argv[3]);
    else if (!strcmp(c, "pause") && argc > 2) cmd_pause(argv[2]);
    else if (!strcmp(c, "tick")) cmd_tick();
    else if (!strcmp(c, "version")) cmd_version();
    else if (!strcmp(c, "quit") && argc > 3) cmd_quit(atoi(argv[2]), argv[3]);
    else if (!strcmp(c, "idle") && argc > 2) cmd_idle(atoi(argv[2]));
    else if (!strcmp(c, "which")) cmd_which();
    else if (!strcmp(c, "stress")) cmd_stress();
    else { fprintf(stderr, "unknown command: %s\n", c); return 2; }
    return 0;
}
