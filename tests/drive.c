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
 *   drive seekkeys             the arrow keys: +10 s, -10 s, quick presses, the start

 *   drive keyat <delay ms> <down|up|n|p|right|left|space>   one key after a delay; marks KEY
 *   drive dropfile <delay ms> <path> [shift [extra ms before quitting]]   drag a file onto Peep (XDND) after a delay, with Shift held if
 *                              asked (a real fake key through XTest); marks DROP
 *   drive textsize <ppm prefix>   screenshots after J (larger text) and after H (smaller)
 *   drive keyeff <pid>         every key once, tagged, for measuring key-to-screen and key-to-audio times
 *   drive rendereff            fade, resize, steady redraw and fullscreen, tagged, for measuring drawing
 *   drive spamkeys <pid> <n> <gap_us>   hold-down-style spam of each key, tagged, to measure lag and side effects
 *   drive spamtracks <ppm prefix>       the same for next/previous, with screenshots
 *   drive seekcost             lone seek keys, then bursts, timestamped, to measure what each key costs
 *   drive seekaudio            many kinds of seeking, for checking the audio stays clean
 *   drive tick                 how often the screen is redrawn
 *   drive volhold              hold the volume keys down (key repeat)
 *   drive tracks               next/previous timing and behaviour
 *   drive fullscreen           enter/leave fullscreen, pointer idle and moving
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
#include <dlfcn.h>
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
static int fs_on, fs_saved[4];
static void wm_event(XEvent *e)
{
    if (e->type == ClientMessage && e->xclient.message_type == XInternAtom(d, "_NET_WM_STATE", 0)) {
        /* a window asking to be made (or no longer be) fullscreen: do what a window manager does */
        int act = e->xclient.data.l[0], want = act == 2 ? !fs_on : act == 1;
        Window ww = e->xclient.window;
        if (want && !fs_on) {
            XWindowAttributes a;
            XGetWindowAttributes(d, ww, &a);
            fs_saved[0] = a.x; fs_saved[1] = a.y; fs_saved[2] = a.width; fs_saved[3] = a.height;
            XMoveResizeWindow(d, ww, 0, 0, DisplayWidth(d, 0), DisplayHeight(d, 0));
        } else if (!want && fs_on)
            XMoveResizeWindow(d, ww, fs_saved[0], fs_saved[1], fs_saved[2], fs_saved[3]);
        fs_on = want;
    }
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

static void keymod(KeySym ks, unsigned state)
{
    XEvent e = {0};
    e.xkey.state = state;
    e.xkey.type = KeyPress;
    e.xkey.window = w;
    e.xkey.root = R;
    e.xkey.keycode = XKeysymToKeycode(d, ks);
    e.xkey.same_screen = 1;
    XSendEvent(d, w, 1, KeyPressMask, &e);
    XSync(d, 0);
}
static void key(KeySym ks) { keymod(ks, 0); }
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
    if (getenv("WIN_SIZE")) { /* measure at another window size */
        int n = atoi(getenv("WIN_SIZE"));
        XResizeWindow(d, w, n, n);
        XSync(d, 0);
        ms(800);
    }
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
    {   /* how much of the window the controls cover: the rows that differ from the bare cover */
        int first = H;
        for (int y = 0; y < H && first == H; y++) {
            double d = 0;
            for (int x = 0; x < W * 3; x++) d += abs(on[y * W * 3 + x] - bare[y * W * 3 + x]);
            if (d / (W * 3) > 1.5) first = y;
        }
        printf("controls_height_pct=%.1f\nwindow=%dx%d\n", 100.0 * (H - first) / H, W, H);
    }
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
    {   /* the play/pause button: centred, directly above the progress bar (same layout as gfx.asm) */
        int u = (W < H ? W : H) >> 5;
        if (u < 6) u = 6;
        u = u * 19 / 20;
        int pad = u * 3 / 2, bh = u / 5 < 2 ? 2 : u / 5;
        click(W / 2, H - pad - bh - u / 2 - u);
    }
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

/* ---- seekkeys: the arrow keys move playback by 10 s ---------------------------- */
static void cmd_seekkeys(void)
{
    need_window();
    ms(1500);
    mark("PROGLOG", "MARK", "R1");    key(XK_Right); ms(700);        /* +10 s */
    mark("PROGLOG", "MARK", "R2");    key(XK_Right); ms(700);        /* +10 s */
    mark("PROGLOG", "MARK", "L1");    key(XK_Left);  ms(700);        /* -10 s */
    mark("PROGLOG", "MARK", "L2");    key(XK_Left);  ms(700);        /* -10 s */
    mark("PROGLOG", "MARK", "L3");    key(XK_Left);  ms(700);        /* less than 10 s in: stops at 0:00 */
    mark("PROGLOG", "MARK", "BURST");                                /* three quick presses add up: +30 s */
    for (int i = 0; i < 3; i++) { key(XK_Right); ms(4); }
    ms(700);
    mark("PROGLOG", "MARK", "NET");                                  /* left, left, right: net -10 s */
    key(XK_Left); ms(4); key(XK_Left); ms(4); key(XK_Right); ms(700);
    mark("PROGLOG", "MARK", "END");
    key(XK_q);
}

/* ---- seekcost: what an arrow key costs, alone and in a burst ------------------- */
static void cmd_seekcost(void)
{
    need_window();
    ms(1500);
    for (int i = 0; i < 6; i++) {                       /* lone presses, 500 ms apart */
        mark("PROGLOG", "MARK", "K");
        key(i % 2 ? XK_Left : XK_Right);
        ms(500);
    }
    mark("PROGLOG", "MARK", "BURST");                   /* 3 right then 3 left, 2 ms apart: net zero */
    for (int i = 0; i < 6; i++) { key(i < 3 ? XK_Right : XK_Left); ms(2); }
    ms(700);
    mark("PROGLOG", "MARK", "END");
    key(XK_q);
}

/* ---- seekaudio: every kind of seeking, to check the audio itself stays clean ---- */
static void cmd_seekaudio(void)
{
    need_window();
    ms(1500);
    for (int i = 0; i < 4; i++) { key(i % 2 ? XK_Left : XK_Right); ms(400); }   /* slow, alternating */
    for (int i = 0; i < 30; i++) { key(i % 2 ? XK_Left : XK_Right); ms(35); }   /* rapid, alternating, net zero */
    ms(300);
    mark("PROGLOG", "MARK", "PAUSE");
    key(XK_space);
    ms(300);
    for (int i = 0; i < 4; i++) { key(i % 2 ? XK_Left : XK_Right); ms(50); }    /* seeking while paused */
    ms(300);
    mark("PROGLOG", "MARK", "RESUME");
    key(XK_space);
    ms(500);
    for (int i = 0; i < 3; i++) { key(XK_Left); ms(33); }                       /* held left: stops at the start */
    ms(400);
    for (int r = 0; r < 2; r++) {                                               /* held right, then held left */
        for (int i = 0; i < 3; i++) { key(XK_Right); ms(33); }                  /* +30 s */
        ms(400);
        for (int i = 0; i < 3; i++) { key(XK_Left); ms(33); }                   /* -30 s */
        ms(400);
    }
    ms(300);
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
    key(XK_g);
    sleep(7);
    mark("LATLOG", "MARK", "END");
    key(XK_q);
}

/* ---- volhold: volume keys held down at the keyboard repeat rate --------------- */
static void cmd_volhold(void)
{
    need_window();
    ms(1500);
    mark("PROGLOG", "MARK", "HOLD");
    for (int i = 0; i < 45; i++) { key(XK_Down); ms(33); }
    for (int i = 0; i < 45; i++) { key(XK_Up); ms(33); }
    mark("PROGLOG", "MARK", "RELEASED");
    ms(600);
    key(XK_q);
}

/* ---- fullscreen -------------------------------------------------------------------- */
static void pump(int msec) /* wait, but keep acting as the window manager */
{
    double end = now() + msec;
    while (now() < end) {
        while (XPending(d)) { XEvent e; XNextEvent(d, &e); wm_event(&e); }
        usleep(1500);
    }
}
static void cmd_fullscreen(void)
{
    open_display();
    XSelectInput(d, R, SubstructureRedirectMask); /* we are the window manager */
    outside();
    find_window();
    wait_viewable(1);
    pump(1500);
    int W, H;
    win_size(&W, &H);
    key(XK_Tab);
    warp(W / 2, H / 2);
    pump(600);
    mark("LATLOG", "MARK", "WINDOWED");
    for (int i = 0; i < 6; i++) { warp(W / 2 + 10 * i, H / 2 + 5 * i); pump(60); } /* moves while windowed */
    mark("LATLOG", "MARK", "ENTER");
    key(XK_f);
    pump(1300);
    mark("LATLOG", "MARK", "MOVE1");
    warp(DisplayWidth(d, 0) / 2, DisplayHeight(d, 0) / 2);
    pump(3600);                                    /* the pointer rests: controls fade, pointer hides */
    mark("LATLOG", "MARK", "MOVE2");
    warp(DisplayWidth(d, 0) / 2 + 40, DisplayHeight(d, 0) / 2 + 20);
    pump(700);
    mark("LATLOG", "MARK", "EXIT");
    key(XK_f);
    pump(1300);
    mark("LATLOG", "MARK", "END");
    key(XK_q);
}

/* ---- tracks: next / previous --------------------------------------------------- */
static void mark2(const char *name) { mark("LATLOG", "MARK", name); mark("PROGLOG", "MARK", name); }
static void cmd_tracks(void)
{
    need_window();
    ms(1500);
    mark2("NEXT");  key(XK_n); ms(700);                        /* next */
    mark2("PREV");  key(XK_p); ms(700);                        /* previous (under 3 s in) */
    mark2("RAPID");                                            /* five quick presses */
    for (int i = 0; i < 5; i++) { key(XK_n); ms(25); }
    mark2("RAPID_END");
    ms(800);
    mark2("LAST");  key(XK_n); ms(900);                        /* next on the last track */
    mark2("END");
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
/* ---- keyeff: every key once, tagged ------------------------------------------- */
static void cmd_keyeff(int pid)
{
    static const struct { const char *name; KeySym ks; unsigned st; int gap; } seq[] = {
        { "pause", XK_space, 0, 450 },   { "resume", XK_space, 0, 450 },
        { "seek_fwd", XK_Right, 0, 450 }, { "seek_back", XK_Left, 0, 450 },
        { "vol_down", XK_Down, 0, 450 },  { "vol_up", XK_Up, 0, 450 },
        { "next", XK_n, 0, 600 },         { "prev", XK_p, 0, 600 },
        { "ui_hide", XK_Tab, 0, 450 },    { "ui_show", XK_Tab, 0, 450 },
        { "blank_on", XK_Tab, ShiftMask, 450 }, { "blank_off", XK_Tab, ShiftMask, 450 },
        { "font", XK_g, 0, 450 },         { "version", XK_v, 0, 2300 },
    };
    need_window();
    ms(1500);
    key(XK_Tab);
    inside();
    ms(600);
    for (unsigned i = 0; i < sizeof seq / sizeof *seq; i++) {
        mark2(seq[i].name);
        keymod(seq[i].ks, seq[i].st);
        ms(seq[i].gap);
    }
    double t0 = now();
    mark2("quit");
    key(XK_q);
    for (int i = 0; i < 4000; i++) {
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

/* ---- rendereff: the ways the picture changes, tagged ------------------------------ */
static void cmd_rendereff(void)
{
    open_display();
    XSelectInput(d, R, SubstructureRedirectMask);      /* we are the window manager */
    outside();
    find_window();
    wait_viewable(1);
    pump(1500);
    int W, H;
    win_size(&W, &H);
    mark2("BEGIN_steady_hidden");  pump(2000);          /* controls hidden: nothing should redraw */
    mark2("BEGIN_show_controls");
    key(XK_Tab);
    pump(300);
    mark2("BEGIN_fade_in");        warp(W / 2, H / 2); pump(800);
    mark2("BEGIN_steady_shown");   pump(3000);          /* controls shown: the clock, once a second */
    mark2("BEGIN_fade_out");       outside(); pump(800);
    warp(W / 2, H / 2);
    pump(700);
    mark2("BEGIN_resize");
    for (int i = 0; i < 24; i++) {                      /* a drag: larger, then smaller, 30 ms apart */
        int s = 300 + (i < 12 ? i : 24 - i) * 20;
        char nm[48];
        snprintf(nm, sizeof nm, "STEP_%d_%dx%d", i, s, s);
        mark2(nm);
        XResizeWindow(d, w, s, s);
        XSync(d, 0);
        pump(30);
    }
    pump(400);
    mark2("END_resize");
    win_size(&W, &H);
    outside();
    pump(700);
    mark2("BEGIN_fullscreen_on");  key(XK_f); pump(1300);
    mark2("BEGIN_fullscreen_off"); key(XK_f); pump(1300);
    mark2("END");
    key(XK_q);
}

/* ---- spam: the same key many times, as fast as possible ---------------------------- */
static void spam(const char *name, KeySym ks, unsigned st, int n, int gap_us, int settle_ms)
{
    char b[64];
    snprintf(b, sizeof b, "S_%s_BEGIN", name); mark2(b);
    for (int i = 0; i < n; i++) { keymod(ks, st); if (gap_us) usleep(gap_us); }
    snprintf(b, sizeof b, "S_%s_END", name);   mark2(b);
    ms(settle_ms);
    snprintf(b, sizeof b, "S_%s_SETTLE", name); mark2(b);
}
static void cmd_spamkeys(int pid, int n, int gap_us)
{
    need_window();
    ms(1500);
    key(XK_Tab);
    inside();
    ms(500);
    n &= ~1;                                              /* even: toggles end where they began */
    spam("seek_fwd", XK_Right, 0, 20, gap_us, 300);       /* 20 x 10 s = 200 s */
    spam("seek_back", XK_Left, 0, 20, gap_us, 300);
    spam("vol_down", XK_Down, 0, n, gap_us, 300);
    spam("vol_up", XK_Up, 0, n, gap_us, 300);
    spam("pause", XK_space, 0, n, gap_us, 300);
    spam("ui", XK_Tab, 0, n, gap_us, 300);
    spam("blank", XK_Tab, ShiftMask, n, gap_us, 300);
    spam("font", XK_g, 0, n, gap_us, 300);
    spam("version", XK_v, 0, n, gap_us, 300);
    double t0 = now();
    key(XK_q);
    for (int i = 0; i < 4000; i++) {
        char f[64], bb[512];
        snprintf(f, sizeof f, "/proc/%d/stat", pid);
        FILE *s = fopen(f, "r");
        if (!s) break;
        char *p = fgets(bb, sizeof bb, s) ? strrchr(bb, ')') : 0;
        fclose(s);
        if (!p || p[2] == 'Z') break;
        usleep(500);
    }
    printf("quit_ms=%.1f\n", now() - t0);
}
static void cmd_spamtracks(const char *prefix)
{
    char out[512];
    need_window();
    ms(1500);
    spam("next", XK_n, 0, 20, 0, 500);
    snprintf(out, sizeof out, "%s_next.ppm", prefix); shot(out);
    spam("prev", XK_p, 0, 20, 0, 500);
    snprintf(out, sizeof out, "%s_prev.ppm", prefix); shot(out);
    key(XK_q);
}

/* ---- dropfile: drag a file onto the window, as a file manager does (XDND) ----------------- */
static void dnd_msg(Window sw, Atom type, long l1, long l2, long l3, long l4)
{
    XEvent e = {0};
    e.xclient.type = ClientMessage;
    e.xclient.window = w;
    e.xclient.message_type = type;
    e.xclient.format = 32;
    e.xclient.data.l[0] = sw;
    e.xclient.data.l[1] = l1;
    e.xclient.data.l[2] = l2;
    e.xclient.data.l[3] = l3;
    e.xclient.data.l[4] = l4;
    XSendEvent(d, w, 0, NoEventMask, &e);
    XSync(d, 0);
}
static void cmd_keyat(int delay, const char *name)
{
    static const struct { const char *n; KeySym k; } t[] = { { "down", XK_Down }, { "up", XK_Up }, { "n", XK_n },
        { "p", XK_p }, { "right", XK_Right }, { "left", XK_Left }, { "space", XK_space } };
    need_window();
    ms(delay);
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++)
        if (!strcmp(t[i].n, name)) {
            mark("PROGLOG", "MARK", "KEY");
            mark("LATLOG", "MARK", "KEY");
            key(t[i].k);
        }
    ms(900);
    key(XK_q);
}
static void shift_key(int down)
{
    static int (*fake)(Display *, unsigned, int, unsigned long);
    static int tried;
    if (!tried) {
        tried = 1;
        void *h = dlopen("libXtst.so.6", RTLD_NOW);
        if (h) fake = (int (*)(Display *, unsigned, int, unsigned long))dlsym(h, "XTestFakeKeyEvent");
    }
    if (!fake) { puts("error=no XTest"); exit(3); }
    fake(d, XKeysymToKeycode(d, XK_Shift_L), down, 0);
    XSync(d, 0);
}
static void cmd_dropfile(int delay, const char *path, int shift, int extra)
{
    need_window();
    ms(delay);
    if (shift) { shift_key(1); ms(50); }
    Window sw = XCreateSimpleWindow(d, R, 0, 0, 10, 10, 0, 0, 0);
    Atom sel = XInternAtom(d, "XdndSelection", 0), uri = XInternAtom(d, "text/uri-list", 0),
         enter = XInternAtom(d, "XdndEnter", 0), pos = XInternAtom(d, "XdndPosition", 0),
         drop = XInternAtom(d, "XdndDrop", 0), copy = XInternAtom(d, "XdndActionCopy", 0);
    XSetSelectionOwner(d, sel, sw, CurrentTime);
    char text[4200];
    snprintf(text, sizeof text, "file://%s\r\n", path);
    int W, H;
    win_size(&W, &H);
    dnd_msg(sw, enter, 5L << 24, uri, 0, 0);
    dnd_msg(sw, pos, 0, ((long)(W / 2) << 16) | (H / 2), 0, copy);
    mark("PROGLOG", "MARK", "DROP");
    mark("LATLOG", "MARK", "DROP");
    dnd_msg(sw, drop, 0, 0, 0, 0);
    double end = now() + 600;
    while (now() < end) {                         /* we are the selection owner: answer Peep's request */
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type == SelectionRequest) {
                XSelectionRequestEvent *r = &e.xselectionrequest;
                XChangeProperty(d, r->requestor, r->property, r->target, 8, PropModeReplace,
                                (unsigned char *)text, (int)strlen(text));
                XEvent n = {0};
                n.xselection.type = SelectionNotify;
                n.xselection.requestor = r->requestor;
                n.xselection.selection = r->selection;
                n.xselection.target = r->target;
                n.xselection.property = r->property;
                n.xselection.time = r->time;
                XSendEvent(d, r->requestor, 0, NoEventMask, &n);
                XSync(d, 0);
            }
        }
        usleep(1000);
    }
    if (shift) shift_key(0);
    ms(extra);
    key(XK_q);
}

static void cmd_textsize(const char *prefix)
{
    char out[512];
    need_window();
    ms(1500);
    key(XK_Tab);
    inside();
    ms(500);
    snprintf(out, sizeof out, "%s_0.ppm", prefix); shot(out);
    for (int i = 0; i < 3; i++) { key(XK_j); ms(150); }
    ms(2300);
    snprintf(out, sizeof out, "%s_up.ppm", prefix); shot(out);
    for (int i = 0; i < 8; i++) { key(XK_h); ms(150); }
    ms(2300);
    snprintf(out, sizeof out, "%s_down.ppm", prefix); shot(out);
    key(XK_q);
}

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
    key(XK_f); sleep(1); key(XK_f); sleep(1); key(XK_f); sleep(1);
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
    else if (!strcmp(c, "seekkeys")) cmd_seekkeys();
    else if (!strcmp(c, "keyeff") && argc > 2) cmd_keyeff(atoi(argv[2]));
    else if (!strcmp(c, "rendereff")) cmd_rendereff();
    else if (!strcmp(c, "spamkeys") && argc > 4) cmd_spamkeys(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    else if (!strcmp(c, "spamtracks") && argc > 2) cmd_spamtracks(argv[2]);
    else if (!strcmp(c, "keyat") && argc > 3) cmd_keyat(atoi(argv[2]), argv[3]);
    else if (!strcmp(c, "dropfile") && argc > 3) cmd_dropfile(atoi(argv[2]), argv[3], argc > 4 && !strcmp(argv[4], "shift"), argc > 5 ? atoi(argv[5]) : 0);
    else if (!strcmp(c, "textsize") && argc > 2) cmd_textsize(argv[2]);
    else if (!strcmp(c, "seekcost")) cmd_seekcost();
    else if (!strcmp(c, "seekaudio")) cmd_seekaudio();
    else if (!strcmp(c, "tick")) cmd_tick();
    else if (!strcmp(c, "version")) cmd_version();
    else if (!strcmp(c, "volhold")) cmd_volhold();
    else if (!strcmp(c, "tracks")) cmd_tracks();
    else if (!strcmp(c, "fullscreen")) cmd_fullscreen();
    else if (!strcmp(c, "quit") && argc > 3) cmd_quit(atoi(argv[2]), argv[3]);
    else if (!strcmp(c, "idle") && argc > 2) cmd_idle(atoi(argv[2]));
    else if (!strcmp(c, "which")) cmd_which();
    else if (!strcmp(c, "stress")) cmd_stress();
    else { fprintf(stderr, "unknown command: %s\n", c); return 2; }
    return 0;
}
