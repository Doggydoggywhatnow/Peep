#!/usr/bin/env python3
"""Peep test suite.  Run it with `make test`, or:

    python3 tests/run.py [--list] [name ...]

It builds Peep, starts its own virtual X display (Xvfb), plays test media
through a model sound device (tests/shim.c) and drives the real program with
key presses (tests/drive.c). See tests/README.md for what each check proves
and what it needs; checks whose tools are missing are skipped, not failed.
"""
import argparse
import array
import glob
import hashlib
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
import wave
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
BUILD = ROOT / "build" / "tests"
PEEP = Path(os.environ.get("PEEP_BIN") or ROOT / "build" / "peep")  # PEEP_BIN: test another build
DRIVE = BUILD / "drive"
SHIM = BUILD / "shim.so"
CODEC = BUILD / "codec_seek"
ASSETS = BUILD / "assets"
LOGS = BUILD / "logs"
HOME = BUILD / "home"
DISPLAY = ":97"
SR = 44100


class Skip(Exception):
    pass


def have(*tools):
    return all(shutil.which(t) for t in tools)


def need(*tools):
    missing = [t for t in tools if not shutil.which(t)]
    if missing:
        raise Skip("needs " + ", ".join(missing))


def need_pil():
    try:
        import PIL  # noqa: F401
    except ImportError:
        raise Skip("needs Pillow (python3 -m pip install pillow)")


# ---------------------------------------------------------------- build / env
def build():
    BUILD.mkdir(parents=True, exist_ok=True)
    if not PEEP.exists() or not (ROOT / "build" / "codecs.o").exists():
        subprocess.run(["make", "-C", str(ROOT)], check=True, stdout=subprocess.DEVNULL)
    cflags = ["-O1", "-w"]
    codecs = ROOT / "build" / "codecs.o"
    for out, inputs, cmd in (
        (DRIVE, [TESTS / "drive.c"],
         ["gcc", *cflags, str(TESTS / "drive.c"), "-o", str(DRIVE), "-lX11", "-lXext"]),
        (SHIM, [TESTS / "shim.c"],
         ["gcc", *cflags, "-shared", "-fPIC", str(TESTS / "shim.c"), "-o", str(SHIM),
          "-ldl", "-lpthread", "-lX11"]),
        (CODEC, [TESTS / "codec_seek.c", codecs, ROOT / "build" / "dec.o", ROOT / "build" / "flac.o",
                 ROOT / "build" / "wav.o"],
         ["gcc", *cflags, str(TESTS / "codec_seek.c"), str(ROOT / "build" / "dec.o"),
          str(ROOT / "build" / "flac.o"), str(ROOT / "build" / "wav.o"), str(codecs), "-o", str(CODEC),
          "-lm"]),
    ):
        if out.exists() and all(out.stat().st_mtime > i.stat().st_mtime for i in inputs):
            continue  # up to date
        subprocess.run(cmd, check=True)


_xvfb = None


def start_display():
    global _xvfb
    if _xvfb:
        return
    sock = Path("/tmp/.X11-unix") / ("X" + DISPLAY[1:])
    _xvfb = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", "1600x1200x24"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    for _ in range(100):
        if sock.exists():
            time.sleep(0.2)
            return
        time.sleep(0.05)
    raise RuntimeError("Xvfb did not start")


def stop_display():
    if _xvfb:
        _xvfb.kill()


def reset_logs():
    LOGS.mkdir(parents=True, exist_ok=True)
    for n in ("heard.raw", "prog.log", "lat.log"):
        (LOGS / n).write_bytes(b"")


def env(preload=True, **extra):
    e = dict(os.environ)
    e.update(DISPLAY=DISPLAY, HOME=str(HOME), XDG_DATA_HOME=str(HOME / "xdg"),
             SIM_OPEN_MS="40", HEARD=str(LOGS / "heard.raw"),
             PROGLOG=str(LOGS / "prog.log"), LATLOG=str(LOGS / "lat.log"))
    if preload:
        e["LD_PRELOAD"] = str(SHIM)
    e.update(extra)
    return e


@contextmanager
def peep(args, wrapper=(), **envx):
    """Run Peep on `args` with the model sound device; always cleaned up."""
    reset_logs()
    p = subprocess.Popen([*wrapper, str(PEEP), *map(str, args)], env=env(**envx),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    try:
        yield p
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()


def drive(*args, timeout=90):
    r = subprocess.run([str(DRIVE), *map(str, args)], env=env(preload=False),
                       capture_output=True, text=True, timeout=timeout)
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    if "error" in out:
        raise AssertionError("driver: %s" % out["error"])
    if r.returncode != 0:
        raise AssertionError("the test driver crashed (exit %d) %s" % (r.returncode, r.stderr.strip()))
    return out


# ------------------------------------------------------------------ test media
def asset(name, make):
    """Build a test file or folder once. It is made under a temporary name and
    renamed only when complete, so a failed build never leaves a broken asset."""
    p = ASSETS / name
    if not p.exists():
        ASSETS.mkdir(parents=True, exist_ok=True)
        tmp = ASSETS / (name + ".tmp" + p.suffix)
        if tmp.is_dir():
            shutil.rmtree(tmp)
        elif tmp.exists():
            tmp.unlink()
        make(tmp)
        tmp.rename(p)
    return p


def write_wav(path, frames_bytes):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames_bytes)


def ramp_wav():
    """40 s in which every frame is unique: a gap or a repeat is detectable."""
    def make(p):
        n = SR * 40
        rnd = random.Random(7)
        inter = array.array("h", bytes(n * 4))
        inter[0::2] = array.array("h", [((i * 7) % 65536) - 32768 for i in range(n)])
        inter[1::2] = array.array("h", [rnd.randint(-20000, 20000) for _ in range(n)])
        write_wav(p, inter.tobytes())
    return asset("ramp.wav", make)


def pair_dir():
    def make(p):
        import math
        p.mkdir()
        for name, k in (("a.wav", 0.05), ("b.wav", 0.1)):
            data = array.array("h", bytes(SR * 3 * 4))
            data[0::2] = array.array("h", [int(8000 * math.sin(i * k)) for i in range(SR * 3)])
            write_wav(p / name, data.tobytes())
    return asset("pair", make)


def cover_jpg(path, size=(1200, 1200)):
    need_pil()
    from PIL import Image, ImageDraw
    w, h = size
    im = Image.new("RGB", size)
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (x * 255 // w, y * 255 // h, 128 if ((x // 60 + y // 60) % 2) else 40)
    d = ImageDraw.Draw(im)
    for i in range(0, w, 40):
        d.line([(i, 0), (w - i, h)], fill=(255, 255, 255), width=3)
    d.ellipse([w // 4, h // 4, 3 * w // 4, 3 * h // 4], outline=(255, 255, 0), width=12)
    im.save(path, quality=92)


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *map(str, args)], check=True)


def sine(secs):
    return ["-f", "lavfi", "-i", "sine=frequency=440:duration=%d" % secs]


def test_mp3():
    """30 s, with a 1200x1200 cover: Peep opens at the cover's size."""
    def make(p):
        need("ffmpeg")
        cov = asset("cover.jpg", cover_jpg)
        ffmpeg(*sine(30), "-i", cov, "-map", 0, "-map", 1, "-c:a", "libmp3lame", "-b:a", "128k",
               "-c:v", "copy", "-id3v2_version", "3", "-metadata", "title=Test", p)
    return asset("test.mp3", make)


def long_mp3():
    """5 minutes, no cover: a plain 480x480 window."""
    def make(p):
        need("ffmpeg")
        ffmpeg(*sine(300), "-ac", "2", "-c:a", "libmp3lame", "-b:a", "192k", p)
    return asset("long.mp3", make)


def album_dir():
    """Three tracks with red, green and blue covers (the green one is wider)."""
    def make(p):
        need("ffmpeg")
        need_pil()
        from PIL import Image
        p.mkdir()
        for i, colour in enumerate(((200, 40, 40), (40, 200, 40), (40, 40, 200))):
            size = (1400, 1000) if i == 1 else (1400, 1400)
            Image.new("RGB", size, colour).save(p / ("c%d.jpg" % i), quality=90)
            ffmpeg(*sine(20), "-i", p / ("c%d.jpg" % i), "-map", 0, "-map", 1, "-c:a",
                   "libmp3lame", "-b:a", "128k", "-c:v", "copy", "-id3v2_version", "3",
                   "-metadata", "title=Track %d" % i, p / ("t%d.mp3" % i))
            (p / ("c%d.jpg" % i)).unlink()
    return asset("album", make)


def tracks_dir():
    """Three 12 s tracks whose every frame is unique: which one is playing is certain."""
    def make(p):
        p.mkdir()
        for i in range(3):
            n = SR * 12
            rnd = random.Random(100 + i)
            inter = array.array("h", bytes(n * 4))
            inter[0::2] = array.array("h", [rnd.randint(-20000, 20000) for _ in range(n)])
            inter[1::2] = array.array("h", [rnd.randint(-20000, 20000) for _ in range(n)])
            write_wav(p / ("t%d.wav" % i), inter.tobytes())
    return asset("tracks3", make)


def converted(ext, *codec):
    def make(p):
        need("ffmpeg")
        ffmpeg("-i", long_mp3(), *codec, p)
    return asset("long." + ext, make)


# ------------------------------------------------------------------ log parsing
def read_lat():
    frames, keys, marks = [], [], {}
    for line in (LOGS / "lat.log").read_text().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "CUR":
            continue                  # pointer visibility: see read_cursor
        if p[0] == "KEY":
            keys.append(float(p[1]))
        elif p[0] == "MARK":
            marks[p[2]] = float(p[1])
        else:
            frames.append((float(p[0]), p[1]))
    return frames, keys, marks


def read_cursor():
    """[(ms, "hide" | "show")] for every time Peep hid or showed the pointer."""
    return [(float(l.split()[1]), l.split()[2]) for l in (LOGS / "lat.log").read_text().splitlines()
            if l.startswith("CUR ")]


def read_sizes():
    """[(ms, (width, height))] for every frame Peep uploaded."""
    out = []
    for l in (LOGS / "lat.log").read_text().splitlines():
        p = l.split()
        if len(p) == 3 and p[0][0].isdigit() and "x" in p[2]:
            w, h = p[2].split("x")
            out.append((float(p[0]), (int(w), int(h))))
    return out


def read_prog():
    prog, marks, drops = [], {}, []
    for line in (LOGS / "prog.log").read_text().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "MARK":
            marks[p[2]] = float(p[1])
        elif p[0] == "DROP":
            drops.append((float(p[1]), int(p[2]), int(p[3])))
        else:
            prog.append((float(p[0]), int(p[1])))
    return prog, marks, drops


def progress_at(prog, t):
    best = None
    for tt, pp in prog:
        if tt <= t:
            best = pp
    return best


def wav_data(path):
    return Path(path).read_bytes()[44:]


# ------------------------------------------------------------------------ tests
CHECKS = []


def check(f):
    CHECKS.append(f)
    return f


@check
def resize_sync():
    """Resizing asks the window manager to wait for each frame (smooth drag)."""
    with peep([]):
        r = drive("sync")
    assert r["advertises_sync"] == 1, "Peep does not advertise _NET_WM_SYNC_REQUEST"
    assert r["acked"] == 40, "only %d of 40 resize steps were acknowledged" % r["acked"]
    return "40/40 steps acknowledged, %.1f ms each" % r["ms_per_step"]


@check
def hover_fade_drag():
    """Controls show only under the pointer, fade out in 0.5 s; art drags, buttons click."""
    need_pil()
    with peep([test_mp3()]):
        r = drive("hover")
    assert r["outside_diff"] < 0.5, "controls visible with the pointer outside"
    assert r["inside_diff"] > 5, "controls not shown with the pointer inside"
    assert 55 <= r["fade_100_pct"] <= 95, "fade at 100 ms is %d%%" % r["fade_100_pct"]
    assert r["fade_250_pct"] < r["fade_100_pct"] and r["fade_400_pct"] < r["fade_250_pct"], \
        "fade is not monotonic"
    assert r["fade_700_pct"] == 0, "a ghost of the controls remains (%d%%)" % r["fade_700_pct"]
    # 33.7% of the window before 0.2.13; the buttons now share the time row, about 30% shorter
    assert 18.0 <= r["controls_height_pct"] <= 25.5, \
        "the controls cover %.1f%% of the window (want about 23.6%%)" % r["controls_height_pct"]
    assert r["art_click_moves"] == 1, "a click on the art did not start a window drag"
    assert r["button_click_moves"] == 0, "a click on a button started a window drag"
    return "fade %d/%d/%d/%d%%" % (r["fade_100_pct"], r["fade_250_pct"], r["fade_400_pct"],
                                   r["fade_700_pct"])


@check
def seek_latency():
    """The clock changes in the same frame as the arrow key (was 250 ms)."""
    with peep([long_mp3()]):
        drive("latency")
    frames, keys, _ = read_lat()
    assert len(keys) == 6, "only %d key presses were logged" % len(keys)
    waits = []
    for k in keys:
        before = [h for t, h in frames if t < k]
        assert before, "no frame drawn before the key"
        nxt = next((t - k for t, h in frames if t >= k and h != before[-1]), None)
        assert nxt is not None, "the screen never changed after a seek key"
        waits.append(nxt)
    assert max(waits) < 20, "slowest reaction %.1f ms" % max(waits)
    return "slowest %.1f ms" % max(waits)


def settled_clock(seq):
    """Hash of the time text after a burst of keys (the paused clock, drawn)."""
    need_pil()
    from PIL import Image
    out = LOGS / "burst.ppm"
    with peep([long_mp3()]):
        drive("burst", seq, out)
    im = Image.open(out).convert("L")
    w, h = im.size
    return hashlib.md5(im.crop((0, int(h * 0.875), w // 2, int(h * 0.945))).tobytes()).hexdigest()


@check
def seek_settle():
    """After key bursts the clock reads the right time (net +/-10 s per key)."""
    same = (("RR", "R.R.L.R"), ("RRRRRLL", "RRR"), ("LLL", "L"))  # equal net seek
    for a, b in same:
        ha, hb = settled_clock(a), settled_clock(b)
        assert ha == hb, "%r and %r should read the same time" % (a, b)
    assert settled_clock("R") != settled_clock("RR"), "one more key did not move the clock"
    return "%d equivalent sequences agree" % len(same)


@check
def pause_silence():
    """Pause silences the music within ~one audio chunk; resume loses and repeats nothing."""
    with peep([ramp_wav()]):
        drive("pause", "plain")
    prog, marks, drops = read_prog()
    tails = []
    for p, r in (("PAUSE", "RESUME"), ("PAUSE2", "RESUME2")):
        tails.append((progress_at(prog, marks[r] - 5) - progress_at(prog, marks[p])) / 44.1)
    assert max(tails) < 40, "sound kept playing %.0f ms after pause" % max(tails)
    assert len(drops) >= 2, "pause did not drop the queued audio"
    src, heard = wav_data(ramp_wav()), (LOGS / "heard.raw").read_bytes()
    n = prog[-1][1] * 4
    assert heard[:n] == src[:n], "the heard audio differs from the file (gap or repeat)"
    return "tail %.0f/%.0f ms, %.1f s of audio identical" % (tails[0], tails[1], n / 4 / SR)


@check
def pause_seek_resume():
    """Seeking while paused, then resuming, plays from exactly 10 s later."""
    with peep([ramp_wav()]):
        drive("pause", "seek")
    prog, marks, drops = read_prog()
    pause_drop = next(d for d in drops if d[0] >= marks["PAUSE"])
    last = [d for d in drops if d[0] < marks["RESUME"]][-1]
    heard, src = (LOGS / "heard.raw").read_bytes(), wav_data(ramp_wav())
    probe = heard[last[2] * 4: last[2] * 4 + 16]
    pos = src.find(probe) // 4
    assert pos >= 0, "resumed audio is not from the file"
    want = pause_drop[2] + 10 * SR
    assert pos == want, "resumed at frame %d, expected %d" % (pos, want)
    return "resumed %.3f s after the pause point" % ((pos - pause_drop[2]) / SR)


@check
def arrow_seek():
    """The arrow keys move playback by exactly 10 s: right +10, left -10, quick presses add up, and
    left with less than 10 s played stops at the very start."""
    with peep([ramp_wav()]):
        drive("seekkeys", timeout=60)
    prog, marks, drops = read_prog()
    src, heard = wav_data(ramp_wav()), (LOGS / "heard.raw").read_bytes()

    def pos(idx):
        """Where in the file the heard frame `idx` comes from (every frame of ramp.wav is unique)."""
        k = src.find(heard[idx * 4: idx * 4 + 16])
        return k // 4 if k >= 0 else None
    steps = ["R1", "R2", "L1", "L2", "L3", "BURST", "NET", "END"]
    moved, landed_at = {}, {}
    for a, b in zip(steps, steps[1:]):
        window = [d for d in drops if marks[a] <= d[0] < marks[b]]
        assert window, "%s: the arrow key did not seek (no audio was dropped)" % a
        before = pos(window[0][2] - 4)          # the last frames heard before the first seek
        after = pos(window[-1][2])              # the first frame heard after the last one
        assert before is not None and after is not None, "%s: the audio heard is not from the file" % a
        moved[a] = (after - (before + 4)) / SR  # seconds the playback moved
        landed_at[a] = after
    # (name, what it should do, seconds, how close)
    for name, want, tol in (("R1", +10, 0.02), ("R2", +10, 0.02), ("L1", -10, 0.02), ("L2", -10, 0.02),
                            ("BURST", +30, 0.06), ("NET", -10, 0.06)):
        assert abs(moved[name] - want) <= tol, \
            "%s moved playback by %+.3f s (want %+d s)" % (name, moved[name], want)
    assert landed_at["L3"] == 0, "left near the start landed at frame %d, not at 0:00" % landed_at["L3"]
    return "right %+.2f/%+.2f s, left %+.2f/%+.2f s, 3 quick rights %+.2f s, net %+.2f s, left at the start -> 0:00" % (
        moved["R1"], moved["R2"], moved["L1"], moved["L2"], moved["BURST"], moved["NET"])


@check
def clock_cadence():
    """With the controls shown Peep redraws once a second, and not at all while paused."""
    fonts = glob.glob("/usr/share/fonts/**/DejaVuSans.ttf", recursive=True) or \
        glob.glob("/usr/share/fonts/**/*.ttf", recursive=True)
    fdir = HOME / "xdg" / "peep" / "fonts"
    shutil.rmtree(fdir, ignore_errors=True)
    if fonts:
        fdir.mkdir(parents=True)
        shutil.copy(fonts[0], fdir)
    with peep([long_mp3()]):
        drive("tick", timeout=60)
    frames, _, m = read_lat()

    def seg(a, b):
        fr = [(t, h) for t, h in frames if m[a] <= t < m[b]]
        return fr, len({h for _, h in fr})
    fr, distinct = seg("PLAY", "PAUSE")
    assert 5 <= len(fr) <= 8, "%d redraws in 6 s of playback (want ~6)" % len(fr)
    assert distinct == len(fr), "a redraw showed nothing new"
    frp, _ = seg("PAUSED", "RESUME")
    assert len(frp) <= 1, "%d redraws while paused" % len(frp)
    note = ""
    if fonts:
        fr, _ = seg("NOTICE", "END")
        last = max(t for i, (t, h) in enumerate(fr) if i == 0 or h != fr[i - 1][1]) - m["NOTICE"]
        assert 3000 <= last <= 6800, "the font notice changed last at %.1f s" % (last / 1000)
        note = ", notice expired at %.1f s" % (last / 1000)
    return "%d redraws in 6 s, %d while paused%s" % (len(fr) if not fonts else 6, len(frp), note)


@check
def volume_hold():
    """Holding a volume key down (key repeat) must not make the sound stutter."""
    with peep([ramp_wav()]):
        drive("volhold")
    prog, marks, drops = read_prog()
    t0, t1 = marks["HOLD"], marks["RELEASED"]
    held = [d for d in drops if t0 <= d[0] <= t1]
    worst = run = 0
    for (ta, pa), (tb, pb) in zip(prog, prog[1:]):
        if ta < t0 or tb > t1 + 300:
            continue
        if pb == pa and pa > 0:
            run += tb - ta
        else:
            worst, run = max(worst, run), 0
    assert 1 <= len(held) <= 2, \
        "the audio queue was dropped %d times (a lone press should, a held key should not)" % len(held)
    assert worst < 8, "the sound stalled for %.0f ms" % worst
    # Smoothness: the file's left channel is known in every frame, so the gain actually applied can
    # be estimated (least squares over 64 frames). It must glide; a step would show as a jump.
    src, heard = wav_data(ramp_wav()), (LOGS / "heard.raw").read_bytes()
    a_, b_ = progress_at(prog, t0), progress_at(prog, t1)
    s16, h16 = array.array("h"), array.array("h")
    s16.frombytes(src[: (b_ + 64) * 4]); h16.frombytes(heard[: (b_ + 64) * 4])
    gains = []                      # None where a window was skipped
    top = len(s16) // 2 - 1
    for i in range(a_, b_, 64):
        # the test signal's left channel is a sawtooth: a window holding a wrap would read wildly
        # wrong if playback were out of step (rewinding after a lone press can be, by more under load), so skip it
        if any(abs(s16[2 * min(k + 1, top)] - s16[2 * min(k, top)]) > 2000 for k in range(i - 64, i + 128)):
            gains.append(None)
            continue
        num = sum(h16[2 * k] * s16[2 * k] for k in range(i, i + 64))
        den = sum(s16[2 * k] * s16[2 * k] for k in range(i, i + 64))
        gains.append(256 * num / den if den else 0)
    real = [g for g in gains if g is not None]
    pairs = [(abs(x - y), n) for n, (x, y) in enumerate(zip(gains, gains[1:])) if x is not None and y is not None]
    step, at_win = max(pairs)
    assert min(real) < 5 and max(real) > 250, "the volume did not sweep the whole range"
    assert step < 3, "the gain jumped by %.1f/256 within 64 frames (it should glide): window %d of %d, gains around it %s" % (
        step, at_win, len(gains), [None if g is None else round(g, 1) for g in gains[max(0, at_win - 3): at_win + 5]])
    return "%d queue drops in 3 s of key repeat, no stall, gain moves <= %.1f/256 per 64 frames" % (
        len(held), step)


@check
def track_keys():
    """Next/previous are quick, land on the right track, and the ends of the list behave."""
    need_pil()
    # screen: a real cover decode per track
    with peep([album_dir()]):
        drive("tracks", timeout=60)
    frames, _, m = read_lat()

    def first_change(t0):
        before = [h for t, h in frames if t < t0][-1]
        return next((t - t0 for t, h in frames if t >= t0 and h != before), None)
    nxt, prv = first_change(m["NEXT"]), first_change(m["PREV"])
    assert nxt is not None and nxt < 80, "Next changed the screen after %s ms" % nxt
    assert prv is not None and prv < 80, "Previous changed the screen after %s ms" % prv
    settle = max(t for t, h in frames if m["RAPID"] <= t <= m["RAPID_END"] + 400) - m["RAPID_END"]
    assert settle < 150, "after five quick Nexts the screen settled %.0f ms later" % settle
    # audio: which track is heard, where
    d = tracks_dir()
    data = [wav_data(d / ("t%d.wav" % i)) for i in range(3)]
    with peep([d]):
        drive("tracks", timeout=60)
    prog, marks, drops = read_prog()
    heard = (LOGS / "heard.raw").read_bytes()

    def landed(t0, t1):
        """(track, frame) playback restarted at, for each queue drop in [t0, t1]."""
        out = []
        for t, q, after in drops:
            if t0 <= t <= t1 and after * 4 + 16 <= len(heard):
                probe = heard[after * 4: after * 4 + 16]
                out.append(next(((i, data[i].find(probe) // 4) for i in range(3) if data[i].find(probe) >= 0), None))
        return out
    first = landed(marks["NEXT"], marks["PREV"] - 1)
    assert first and first[-1] == (1, 0), "Next did not start track 2 from its beginning: %s" % first
    back = landed(marks["PREV"], marks["RAPID"] - 1)
    assert back and back[-1] == (0, 0), "Previous (under 3 s in) did not go back to track 1: %s" % back
    rapid = landed(marks["RAPID"], marks["LAST"] - 1)
    assert rapid and rapid[-1] == (2, 0), "five quick Nexts did not land on the last track: %s" % rapid
    assert not landed(marks["LAST"], marks["END"]), "Next on the last track interrupted the music"
    p0, p1 = progress_at(prog, marks["LAST"]), progress_at(prog, marks["END"])
    assert (p1 - p0) / SR > 0.8, "the music stopped after Next on the last track"
    return "next %.0f ms, previous %.0f ms, 5 quick Nexts settle in %.0f ms; last-track Next is a no-op" % (
        nxt, prv, settle)


@check
def fullscreen_pointer():
    """Fullscreen keeps the pointer usable; it hides with the controls once it stops moving."""
    need_pil()
    with peep([test_mp3()]):
        drive("fullscreen", timeout=60)
    frames, _, m = read_lat()
    cur, sizes = read_cursor(), read_sizes()

    def between(rows, a, b):
        return [r_ for r_ in rows if m[a] <= r_[0] < m[b]]
    windowed = [sz for t, sz in sizes if t < m["ENTER"]][-1]
    assert not between(sizes, "WINDOWED", "ENTER"), "windowed Peep redrew for pointer movement"
    # entering: quick, and never a frame at a size the window does not have
    enter = [(t - m["ENTER"], sz) for t, sz in between(sizes, "ENTER", "MOVE1") if t - m["ENTER"] < 500]
    assert enter and enter[0][0] < 80, "the first fullscreen frame took %s ms" % (enter[0][0] if enter else "-")
    assert len(enter) <= 3, "%d frames drawn while entering fullscreen" % len(enter)
    assert all(sz == (1600, 1200) for _, sz in enter), "frames at the wrong size while entering: %s" % enter
    assert not between(cur, "ENTER", "MOVE1"), "the pointer was hidden right after entering fullscreen"
    # still pointer: controls fade (0.5 s), then the pointer hides with them
    hides = [t for t, a in between(cur, "MOVE1", "MOVE2") if a == "hide"]
    assert len(hides) == 1, "the pointer was hidden %d times while resting" % len(hides)
    rest = hides[0] - m["MOVE1"]
    assert 2300 <= rest <= 2800, "the pointer hid %.0f ms after it stopped (want about 2500)" % rest
    fade = between(frames, "MOVE1", "MOVE2")
    assert len(fade) >= 15, "only %d frames in the fade-out" % len(fade)
    assert abs(fade[-1][0] - hides[0]) < 80, "the controls finished fading %.0f ms from the pointer hiding" % (
        fade[-1][0] - hides[0])
    # moving again: pointer and controls back at once
    shows = [t for t, a in between(cur, "MOVE2", "EXIT") if a == "show"]
    assert shows and shows[0] - m["MOVE2"] < 30, "the pointer took %s ms to come back" % (
        shows[0] - m["MOVE2"] if shows else "-")
    back = next((t - m["MOVE2"] for t, h in frames if t >= m["MOVE2"]), None)
    assert back is not None and back < 40, "the controls took %s ms to come back" % back
    # leaving
    leave = [(t - m["EXIT"], sz) for t, sz in between(sizes, "EXIT", "END") if t - m["EXIT"] < 500]
    assert leave and leave[0][0] < 80 and len(leave) <= 3, "leaving fullscreen: %s" % leave
    assert all(sz == windowed for _, sz in leave), "frames at the wrong size while leaving: %s" % leave
    assert not [a for t, a in between(cur, "EXIT", "END") if a == "hide"], "the pointer was hidden after leaving"
    return "pointer hid %.0f ms after resting, back in %.0f ms; %d fade frames; enter/leave %d/%d frames" % (
        rest, shows[0] - m["MOVE2"], len(fade), len(enter), len(leave))


@check
def version_notice():
    """V shows "Peep <version>" for 2 s, costs two frames in all, and matches the README."""
    want = (ROOT / "README.md").read_text().splitlines()[0].removeprefix("# Peep ").strip()
    assert re.fullmatch(r"\d+\.\d+\.\d+", want), "cannot read the version from the README"
    assert ("Peep " + want).encode() in PEEP.read_bytes(), \
        "this build does not contain 'Peep %s' (rebuild after changing the README)" % want
    with peep([long_mp3()]):
        drive("version")
    frames, _, m = read_lat()
    fr = [(t - m["VKEY"], h) for t, h in frames if m["VKEY"] <= t < m["END"]]
    assert len(fr) == 2, "%d frames drawn for the version notice (want 2: show, hide)" % len(fr)
    assert fr[0][0] < 20, "the notice took %.0f ms to appear" % fr[0][0]
    assert 1900 <= fr[1][0] <= 2400, "the notice went away after %.2f s (want 2)" % (fr[1][0] / 1000)
    assert fr[1][1] != fr[0][1], "the notice never changed the picture"
    before = [h for t, h in frames if t < m["VKEY"]][-1]
    assert fr[1][1] == before, "the notice left something on screen"
    return "Peep %s shown for %.2f s, 2 frames" % (want, fr[1][0] / 1000)


@check
def quit_speed():
    """Q exits within milliseconds in every state."""
    pair = pair_dir()
    worst = 0
    for mode in ("playing", "paused", "seeking", "skipping"):
        with peep([pair]) as p:
            r = drive("quit", p.pid, mode)
        assert r["quit_ms"] < 100, "quit while %s took %.0f ms" % (mode, r["quit_ms"])
        worst = max(worst, r["quit_ms"])
    return "slowest %.1f ms" % worst


@check
def track_gap():
    """Moving on to the next track leaves no silent gap."""
    with peep([pair_dir()]):
        drive("idle", 7, timeout=30)
    prog, _, _ = read_prog()
    end = prog[-1][1]
    worst = run = 0
    for (t0, p0), (t1, p1) in zip(prog, prog[1:]):
        if p1 == p0 and 0 < p0 < end - 4410:
            run += t1 - t0
        else:
            worst, run = max(worst, run), 0
    assert worst < 10, "silent for %.0f ms between tracks" % worst
    assert end > 4 * SR, "the second track never played"
    return "longest silence %.0f ms" % worst


@check
def cover_per_track():
    """The cover on screen is the playing track's, even after rapid skipping."""
    need_pil()
    with peep([album_dir()]):
        r = drive("which")
    got = [r.get(k) for k in ("start", "after_n", "after_nn", "after_pp", "after_np6")]
    assert got == ["red", "green", "blue", "red", "red"], "covers shown: %s" % got
    return " -> ".join(got)


@check
def codec_seek():
    """Seeking lands on exactly the right samples in MP3, Ogg, FLAC, 16-bit and 24-bit WAV."""
    need("ffmpeg")
    done = []
    for f, mode in ((long_mp3(), "shim"), (converted("ogg", "-c:a", "libvorbis"), "shim"),
                    (converted("flac", "-c:a", "flac"), "kernel"), (ramp_wav(), "kernel"),
                    (converted("wav", "-c:a", "pcm_s24le"), "kernel")):
        r = subprocess.run([str(CODEC), mode, str(f)], capture_output=True, text=True)
        assert r.returncode == 0, "%s: %s" % (f.suffix, r.stdout.strip() or r.stderr.strip())
        done.append(f.suffix[1:])
    return "exact in " + ", ".join(done)


def decoder_tools():
    """Build lib-Peep's decoder test tools against the objects linked into Peep."""
    need("gcc")
    try:
        import numpy  # noqa: F401
    except ImportError:
        raise Skip("needs numpy (python3 -m pip install numpy)")
    objs = [ROOT / "build" / "dec.o", ROOT / "build" / "flac.o", ROOT / "build" / "wav.o"]
    out = {}
    for name, src, extra in (("peepdump", "peepdump.c", ["-O2", "-DNO_DR"]), ("fuzz", "fuzz.c", ["-O1", "-g"])):
        exe, sp = BUILD / name, TESTS / "decoders" / src
        if not exe.exists() or any(exe.stat().st_mtime <= p.stat().st_mtime for p in [sp, *objs]):
            subprocess.run(["gcc", "-w", *extra, "-I", str(TESTS / "decoders"), "-o", str(exe), str(sp),
                            *map(str, objs)], check=True)
        out[name] = exe
    return out


def run_suite(script, *args, tool=True):
    t = decoder_tools()
    cmd = [sys.executable, str(TESTS / "decoders" / script), *args]
    if tool:
        cmd += ["--tool", str(t["peepdump"])]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    out = (r.stdout + r.stderr).strip()
    assert r.returncode == 0 and " 0 failures" in r.stdout, out[-400:]
    return r.stdout.strip().splitlines()[-1]


@check
def wav_decoder():
    """The built-in 16-bit WAV decoder: header variants, chunk layouts, channel counts, volume, seeking."""
    t = decoder_tools()
    r = subprocess.run([sys.executable, str(TESTS / "decoders" / "testwav.py"), str(t["peepdump"])],
                       capture_output=True, text=True)
    assert r.returncode == 0 and " 0 failures" in r.stdout, (r.stdout + r.stderr).strip()[-400:]
    return r.stdout.strip().splitlines()[-1]


@check
def wavx_decoder():
    """The other WAV formats (8/12/16/20/24/32-bit PCM, 32/64-bit float) against an independent model."""
    return run_suite("testwavx.py", "--run", "240", "--seed", "1")


@check
def flac_decoder():
    """The native FLAC decoder against ground truth: random streams using every feature of the format."""
    return run_suite("mkflac.py", "--run", "120", "--seed", "1")


@check
def flac_crc():
    """Damaged FLAC frames are detected by their CRC, counted, and skipped without stopping playback."""
    t = decoder_tools()
    r = subprocess.run([sys.executable, str(TESTS / "decoders" / "testcrc.py"), "--run", "300", "--seed", "1",
                        "--tool", str(t["peepdump"])], capture_output=True, text=True, timeout=600)
    assert r.returncode == 0 and r.stdout.strip().endswith(" 0 wrong"), (r.stdout + r.stderr).strip()[-400:]
    return r.stdout.strip().splitlines()[-1]


@check
def hires_output():
    """Full-resolution (24-bit and wider) output, volume and the 16-bit conversion, bit-exact against a model."""
    return run_suite("testhires.py", "--run", "120", "--seed", "1", "--no-legacy")


@check
def decoder_fuzz():
    """Mutated WAV and FLAC input never makes the decoders read or write out of bounds (guard pages)."""
    t = decoder_tools()
    seeds = BUILD / "seeds"
    seeds.mkdir(exist_ok=True)
    files = []
    for n in (1, 10, 13, 15, 17, 19):
        f = seeds / ("s%d.flac" % n)
        if not f.exists():
            subprocess.run([sys.executable, str(TESTS / "decoders" / "mkflac.py"), "--gen",
                            str(seeds / ("s%d" % n)), "--seed", str(n)], check=True, capture_output=True)
        files.append(str(f))
    if not (seeds / "w0.wav").exists():
        subprocess.run([sys.executable, str(TESTS / "decoders" / "testwavx.py"), "--gen", str(seeds)],
                       check=True, capture_output=True)
    files += [str(seeds / ("w%d.wav" % n)) for n in range(5)]
    r = subprocess.run([str(t["fuzz"]), "100000", *files], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0 and "no crash" in r.stdout + r.stderr, (r.stdout + r.stderr).strip()[-400:]
    return (r.stdout + r.stderr).strip().splitlines()[-1]


@check
def stress_valgrind():
    """Rapid skipping and fullscreen toggling: no memory errors (valgrind)."""
    need("valgrind")
    need_pil()
    with peep([album_dir()], wrapper=["valgrind", "--error-exitcode=9", "-q"]) as p:
        r = drive("stress", timeout=180)
        try:
            code = p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            raise AssertionError("Peep did not exit after Q")
    assert r.get("done") == 1
    assert code == 0, "valgrind reported memory errors (exit code %d)" % code
    return "no errors"


# ----------------------------------------------------------------------- driver
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", help="run only these checks")
    ap.add_argument("--list", action="store_true", help="list the checks")
    a = ap.parse_args()
    if a.list:
        for c in CHECKS:
            print("%-18s %s" % (c.__name__, c.__doc__))
        return 0
    todo = [c for c in CHECKS if not a.names or c.__name__ in a.names]
    unknown = set(a.names) - {c.__name__ for c in CHECKS}
    if unknown:
        print("unknown check(s):", ", ".join(sorted(unknown)))
        return 2
    for tool in ("gcc", "Xvfb"):
        if not have(tool):
            print("missing required tool:", tool)
            return 2
    build()
    start_display()
    results = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    try:
        for c in todo:
            t0 = time.time()
            try:
                msg = c() or ""
                status = "PASS"
            except Skip as e:
                status, msg = "SKIP", str(e)
            except Exception as e:  # noqa: BLE001
                status, msg = "FAIL", "%s: %s" % (type(e).__name__, e) if not isinstance(
                    e, AssertionError) else str(e)
            results[status] += 1
            print("%-4s %-18s %5.1fs  %s" % (status, c.__name__, time.time() - t0, msg), flush=True)
    finally:
        stop_display()
    print("\n%d passed, %d failed, %d skipped" % (results["PASS"], results["FAIL"], results["SKIP"]))
    return 1 if results["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
