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
import json
import os
import random
import re
import shutil
import signal
import struct
import subprocess
import threading
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
         ["gcc", *cflags, str(TESTS / "drive.c"), "-o", str(DRIVE), "-lX11", "-lXext", "-ldl"]),
        (SHIM, [TESTS / "shim.c"],
         ["gcc", *cflags, "-shared", "-fPIC", str(TESTS / "shim.c"), "-o", str(SHIM),
          "-ldl", "-lpthread", "-lX11"]),
        (CODEC, [TESTS / "codec_seek.c", codecs, ROOT / "build" / "dec.o", ROOT / "build" / "flac.o",
                 ROOT / "build" / "wav.o", ROOT / "build" / "wavc.o"],
         ["gcc", *cflags, str(TESTS / "codec_seek.c"), str(ROOT / "build" / "dec.o"),
          str(ROOT / "build" / "flac.o"), str(ROOT / "build" / "wav.o"), str(ROOT / "build" / "wavc.o"),
          str(codecs), "-o", str(CODEC), "-lm"]),
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


def read_frames():
    """Every frame Peep drew: (ms, checksum, "WxH")."""
    out = []
    for line in (LOGS / "lat.log").read_text().splitlines():
        p = line.split()
        if len(p) == 3 and p[0][0].isdigit():
            out.append((float(p[0]), p[1], p[2]))
    return out


REWINDS = []                 # the REWIND lines of the last read_prog(): (ms, frames taken back, stream length after)


def read_prog():
    global REWINDS
    prog, marks, drops, rewinds = [], {}, [], []
    for line in (LOGS / "prog.log").read_text().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "MARK":
            marks[p[2]] = float(p[1])
        elif p[0] == "DROP":
            drops.append((float(p[1]), int(p[2]), int(p[3])))
        elif p[0] == "REWIND":
            rewinds.append((float(p[1]), int(p[2]), int(p[3])))
        else:
            prog.append((float(p[0]), int(p[1])))
    REWINDS = rewinds
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

# Named groups of checks: `python3 tests/run.py seeking` runs the whole group.
GROUPS = {
    "efficiency": ["key_efficiency", "render_efficiency", "seek_efficiency", "key_spam"],
    "seeking": ["seek_latency", "seek_settle", "arrow_seek", "seek_audio_integrity",
                "seek_efficiency",
                "pause_seek_resume", "codec_seek"],
}


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
    # Between the pauses the audio must be the file, frame for frame. At each pause Peep rewinds to the point being
    # heard, read from the device just before it drops the queue, so the device may play one more frame in between
    # and that frame is heard again: up to 2 frames of overlap per pause, which no ear can hear and no program can avoid.
    cuts = [0] + [d[2] for d in drops if 0 < d[2] < n // 4] + [n // 4]
    want = 0
    for a_, b_ in zip(cuts, cuts[1:]):
        k = src.find(heard[a_ * 4: a_ * 4 + 16]) // 4
        assert src.find(heard[a_ * 4: a_ * 4 + 16]) >= 0 and abs(k - want) <= 2, \
            "after the pause at frame %d the audio resumes at frame %d, not %d (gap or repeat)" % (a_, k, want)
        assert heard[a_ * 4: b_ * 4] == src[k * 4: k * 4 + (b_ - a_) * 4], \
            "the heard audio differs from the file between frames %d and %d" % (a_, b_)
        want = k + (b_ - a_)
    return "tail %.0f/%.0f ms, %.1f s of audio identical (to within 2 frames at each pause)" % (tails[0], tails[1], n / 4 / SR)


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
def seek_audio_integrity():
    """Seeking never garbles the audio: between seeks every sample heard is exactly the file's next one
    (no wrong, repeated, skipped or silent samples, so no distortion or clicks beyond the cut itself),
    through slow, rapid, paused and held-key seeking, and each seek's dropout is short."""
    with peep([ramp_wav()]):
        drive("seekaudio", timeout=60)
    prog, marks, drops = read_prog()
    src, heard = wav_data(ramp_wav()), (LOGS / "heard.raw").read_bytes()
    end = prog[-1][1]                  # frames actually heard (the rest of the file is queued, unheard)
    assert end > 4 * SR, "only %.1f s of audio was heard" % (end / SR)
    assert len(drops) >= 20, "only %d seeks reached the audio device" % len(drops)
    # Each drop of the queue starts a new stretch of the heard audio: the cut. Within a stretch the audio
    # must be the file, frame for frame. (Every frame of ramp.wav is unique, so where it comes from is certain.)
    cuts = sorted({0, *[d[2] for d in drops if 0 < d[2] < end]}) + [end]
    stretches = frames = 0
    for a, b in zip(cuts, cuts[1:]):
        if b - a < 4:
            continue                   # too short to place in the file
        k = src.find(heard[a * 4: a * 4 + 16])
        assert k >= 0 and k % 4 == 0, "heard audio at frame %d (%.2f s) is not from the file" % (a, a / SR)
        p = k // 4
        got, want = heard[a * 4: b * 4], src[p * 4: p * 4 + (b - a) * 4]
        if got != want:
            n = next(i for i in range(0, len(got), 4) if got[i: i + 4] != want[i: i + 4]) // 4
            raise AssertionError("garbled audio: %d frames after a seek, sample %d of the stretch is %s, "
                                 "the file has %s" % (n, n, got[n * 4: n * 4 + 4].hex(), want[n * 4: n * 4 + 4].hex()))
        stretches += 1
        frames += b - a
    # The silence after each seek: from the queue being dropped to the audio playing again.
    paused = (marks["PAUSE"], marks["RESUME"])
    gaps = []
    for t, q, after in drops:
        if paused[0] <= t <= paused[1]:
            continue                   # while paused the silence is the point
        nxt = next((tt for tt, pp in prog if tt > t and pp > after), None)
        if nxt is not None:
            gaps.append(nxt - t)
    assert gaps, "no seek was followed by audio"
    assert max(gaps) < 25, "the sound dropped out for %.0f ms after a seek" % max(gaps)
    return "%d seeks, %d stretches (%.1f s) every sample exactly the file's; longest dropout %.0f ms" % (
        len(drops), stretches, frames / SR, max(gaps))


@check
def seek_efficiency():
    """What an arrow key costs: a lone press reaches the audio within 8 ms and is heard within 12 ms,
    exactly one seek per press, and a burst of six quick presses causes at most six (one per key)."""
    with peep([ramp_wav()]):
        drive("seekcost", timeout=60)
    prog, marks, drops = read_prog()
    keys = [float(l.split()[1]) for l in (LOGS / "prog.log").read_text().splitlines()
            if l.startswith("MARK") and l.split()[2] == "K"]
    assert len(keys) == 6, "only %d key presses were logged" % len(keys)
    t_burst, t_end = marks["BURST"], marks["END"]
    to_drop, to_sound = [], []
    for i, k in enumerate(keys):
        stop = keys[i + 1] if i + 1 < len(keys) else t_burst
        mine = [d for d in drops if k <= d[0] < stop]
        assert len(mine) == 1, "press %d caused %d seeks of the audio queue, not 1" % (i + 1, len(mine))
        t, _, after = mine[0]
        heard = next((tt for tt, pp in prog if tt >= t and pp > after), None)
        assert heard is not None, "press %d was never heard" % (i + 1)
        to_drop.append(t - k)
        to_sound.append(heard - k)
    assert max(to_drop) < 8, "a seek key took %.0f ms to reach the audio" % max(to_drop)
    assert max(to_sound) < 12, "a seek key took %.0f ms to be heard" % max(to_sound)
    burst = [d for d in drops if t_burst <= d[0] < t_end]
    assert len(burst) <= 6, "six quick presses made %d audio seeks" % len(burst)
    return "key to audio %.0f ms, to sound %.0f ms (worst of 6); a burst of 6 made %d seek(s)" % (
        max(to_drop), max(to_sound), len(burst))


REPORTS = BUILD / "efficiency"


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


class CpuSampler:
    """Samples a process's CPU time (ns, from /proc/<pid>/schedstat) every ~2 ms on the same clock as the logs."""
    def __init__(self, pid):
        self.pid, self.samples, self.stop = pid, [], False
        self.t = threading.Thread(target=self.run, daemon=True)
        self.t.start()

    def run(self):
        while not self.stop:
            try:
                ns = int(open("/proc/%d/schedstat" % self.pid).read().split()[0])
            except (OSError, ValueError, IndexError):
                break
            self.samples.append((time.clock_gettime(time.CLOCK_MONOTONIC) * 1e3, ns))
            time.sleep(0.002)

    def at(self, t):
        best = None
        for tt, ns in self.samples:
            if tt <= t:
                best = ns
            else:
                break
        return best

    def used_ms(self, t0, t1):
        a, b = self.at(t0), self.at(t1)
        return None if a is None or b is None else (b - a) / 1e6

    def close(self):
        self.stop = True
        self.t.join(1)


def write_report(name, data, lines):
    REPORTS.mkdir(parents=True, exist_ok=True)
    (REPORTS / (name + ".json")).write_text(json.dumps(data, indent=1))
    (REPORTS / (name + ".txt")).write_text("\n".join(lines) + "\n")


KEY_ORDER = ["pause", "resume", "seek_fwd", "seek_back", "vol_down", "vol_up", "next", "prev",
             "ui_hide", "ui_show", "blank_on", "blank_off", "font", "version"]


@check
def key_efficiency():
    """Every key, once: how long until the screen changes, how many frames it costs, and how long until
    the audio reacts. Every number is written to build/tests/efficiency/keys.json and keys.txt."""
    need_pil()
    with peep([album_dir()]) as p:
        r = drive("keyeff", p.pid, timeout=60)
    frames, _, m = read_lat()
    prog, _, drops = read_prog()
    keys = [k for k in KEY_ORDER if k in m]
    assert len(keys) == len(KEY_ORDER), "only %d of %d keys were logged" % (len(keys), len(KEY_ORDER))
    rows, lines = {}, ["%-10s %9s %7s %9s %10s" % ("key", "screen ms", "frames", "audio ms", "heard ms")]
    nxt = {k: (m[KEY_ORDER[i + 1]] if i + 1 < len(KEY_ORDER) else m["quit"]) for i, k in enumerate(KEY_ORDER)}
    for k in KEY_ORDER:
        t0, t1 = m[k], nxt[k]
        before = [h for t, h in frames if t < t0]
        last = before[-1] if before else None
        mine = [(t, h) for t, h in frames if t0 <= t < t1]
        screen = next((t - t0 for t, h in mine if h != last), None)
        in100 = sum(1 for t, h in mine if t - t0 < 100)
        drop = next((d for d in drops if t0 <= d[0] < t1), None)
        audio = drop[0] - t0 if drop else None
        heard = None
        if drop:
            heard = next((t - t0 for t, pp in prog if drop[0] <= t < t1 and pp > drop[2]), None)
        rows[k] = {"screen_ms": screen, "frames_in_100ms": in100, "frames_until_next_key": len(mine),
                   "audio_ms": audio, "heard_ms": heard}
        f = lambda v: "-" if v is None else "%.1f" % v
        lines.append("%-10s %9s %7d %9s %10s" % (k, f(screen), in100, f(audio), f(heard)))
    rows["quit"] = {"exit_ms": r["quit_ms"]}
    lines.append("%-10s exits in %.1f ms" % ("quit", r["quit_ms"]))
    write_report("keys", rows, lines)
    slow = [k for k in KEY_ORDER if rows[k]["screen_ms"] is None or rows[k]["screen_ms"] > 50]
    assert not slow, "no screen change within 50 ms after: %s (see %s)" % (", ".join(slow), REPORTS / "keys.txt")
    worst = max(rows[k]["screen_ms"] for k in KEY_ORDER)
    return "every key changes the screen in %.1f ms or less (slowest: %s); quit %.1f ms; details in %s" % (
        worst, max(KEY_ORDER, key=lambda k: rows[k]["screen_ms"]), r["quit_ms"], REPORTS / "keys.json")


@check
def render_efficiency():
    """Drawing: frames and CPU per frame while idle, fading, resizing and entering fullscreen, with every
    frame time recorded to build/tests/efficiency/render.json and render.txt."""
    need_pil()
    with peep([album_dir()]) as p:
        cpu = CpuSampler(p.pid)
        try:
            drive("rendereff", timeout=60)
        finally:
            cpu.close()
    frames, _, m = read_lat()
    ft = [(t, h, sz) for t, h, sz in read_frames()]
    names = sorted((t, n[6:]) for n, t in m.items() if n.startswith("BEGIN_"))
    ends = {n: t for n, t in m.items()}
    out, lines = {}, ["%-14s %7s %8s %9s %11s %11s %11s" % (
        "scenario", "frames", "cpu ms", "cpu/frame", "interval p50", "interval max", "first frame")]
    for i, (t0, name) in enumerate(names):
        t1 = names[i + 1][0] if i + 1 < len(names) else m["END"]
        if name == "resize":
            t1 = m["END_resize"]
        fr = [(t, h, sz) for t, h, sz in ft if t0 <= t < t1]
        iv = [b[0] - a[0] for a, b in zip(fr, fr[1:])]
        used = cpu.used_ms(t0, t1)
        d = {"duration_ms": t1 - t0, "frames": len(fr), "cpu_ms": used,
             "cpu_ms_per_frame": (used / len(fr)) if used is not None and fr else None,
             "first_frame_ms": (fr[0][0] - t0) if fr else None,
             "interval_ms": {"min": min(iv) if iv else None, "p50": pct(iv, .5), "p95": pct(iv, .95),
                             "max": max(iv) if iv else None},
             "frame_times_ms": [round(t - t0, 2) for t, h, sz in fr],
             "frame_sizes": sorted({sz for t, h, sz in fr})}
        out[name] = d
        f = lambda v: "-" if v is None else "%.2f" % v
        lines.append("%-14s %7d %8s %9s %11s %11s %11s" % (
            name, len(fr), f(used), f(d["cpu_ms_per_frame"]), f(d["interval_ms"]["p50"]),
            f(d["interval_ms"]["max"]), f(d["first_frame_ms"])))
    steps = []                              # each resize step: time until a frame shows the new size
    for n, t in sorted(m.items(), key=lambda kv: kv[1]):
        if n.startswith("STEP_"):
            _, i, size = n.split("_")
            fr = next(((tt - t, sz) for tt, h, sz in ft if tt >= t and sz == size), None)
            any_fr = next(((tt - t, sz) for tt, h, sz in ft if tt >= t), None)
            steps.append({"step": int(i), "size": size, "frame_with_that_size_ms": fr[0] if fr else None,
                          "first_frame_ms": any_fr[0] if any_fr else None,
                          "first_frame_size": any_fr[1] if any_fr else None})
    out["resize_steps"] = steps
    lat = [s["frame_with_that_size_ms"] for s in steps if s["frame_with_that_size_ms"] is not None]
    lines.append("")
    lines.append("resize steps: %d, new size on screen after p50 %s ms, max %s ms (%d of %d reached the exact size)" % (
        len(steps), "-" if not lat else "%.1f" % pct(lat, .5), "-" if not lat else "%.1f" % max(lat), len(lat), len(steps)))
    write_report("render", out, lines)
    hid, shown = out["steady_hidden"], out["steady_shown"]
    assert hid["frames"] == 0, "%d frames were drawn while the controls were hidden and nothing changed" % hid["frames"]
    assert 2 <= shown["frames"] <= 6, "%d frames in 3 s of shown controls (expected about one a second)" % shown["frames"]
    assert out["fade_in"]["frames"] >= 1 and out["fade_out"]["frames"] >= 10, "the fades drew too few frames"
    cpf = [out[k]["cpu_ms_per_frame"] for k in ("fade_in", "fade_out", "resize", "fullscreen_on")
           if out[k]["cpu_ms_per_frame"] is not None]
    assert cpf and max(cpf) < 25, "a frame cost %.1f ms of CPU" % max(cpf)
    assert lat and max(lat) < 60, "a resize step took %.0f ms to show" % max(lat)
    return "idle %d frames, shown %d/3 s; CPU per frame up to %.2f ms; resize steps p50 %.1f ms, max %.1f ms; details in %s" % (
        hid["frames"], shown["frames"], max(cpf), pct(lat, .5), max(lat), REPORTS / "render.json")


def ramp_long():
    """240 s in which every frame is unique (the left and right samples are the low and high halves of a counter)."""
    def make(p):
        n = SR * 240
        write_wav(p, array.array("I", range(0, n * 7, 7)).tobytes())
    return asset("ramp240.wav", make)


SPAM_KEYS = ("seek_fwd", "seek_back", "vol_down", "vol_up", "pause", "ui", "blank", "font", "version")


def spam_metrics(name, n, m, frames, prog, drops, cpu, paused=False):
    """What one burst of the same key did: lag, frames, audio stalls, CPU, all from the logs."""
    t0, te, ts = m["S_%s_BEGIN" % name], m["S_%s_END" % name], m["S_%s_SETTLE" % name]
    before = [h for t, h in frames if t < t0]
    last = before[-1] if before else None
    mine = [(t, h) for t, h in frames if t0 <= t <= ts]
    first = next((t - t0 for t, h in mine if h != last), None)
    drawn_last = None                       # end of the run of frames (each within 60 ms of the last) that starts
    for t, h in mine:                       # with the burst: later frames are the clock or a fade, not backlog
        if drawn_last is None or t - drawn_last < 60:
            drawn_last = t
        else:
            break
    gaps = [b[0] - a[0] for a, b in zip(prog, prog[1:]) if a[1] == b[1] and t0 <= a[0] and b[0] <= ts]
    run = longest = 0.0
    for (ta, pa), (tb, pb) in zip(prog, prog[1:]):
        if t0 <= ta and tb <= ts and pa == pb:
            run += tb - ta
            longest = max(longest, run)
        else:
            run = 0.0
    alive = (progress_at(prog, ts) or 0) - (progress_at(prog, ts - 150) or 0)
    used = cpu.used_ms(t0, ts) if cpu else None
    return {"keys": n, "sent_ms": te - t0, "keys_per_s": n / max(te - t0, 1e-3) * 1e3,
            "first_screen_ms": first, "last_frame_after_last_key_ms": None if drawn_last is None else max(0.0, drawn_last - te),
            "frames_after_last_key": sum(1 for t, h in mine if t > te),
            "frames": len(mine), "audio_drops": sum(1 for d in drops if t0 <= d[0] <= ts),
            "longest_audio_stall_ms": None if paused else longest,
            "audio_playing_at_end": alive > 4000, "cpu_ms": used,
            "cpu_ms_per_key": None if used is None else used / n}


@check
def key_spam():
    """Spam every key as fast as the X server takes it (about 20,000 a second): Peep must stay alive, drain
    the backlog within 300 ms, keep the audio clean and playing, and apply every seek and track key.
    Per-key lag, frames, stalls and CPU go to build/tests/efficiency/spam.json and spam.txt."""
    need_pil()
    from PIL import Image
    N = 40
    res, lines = {}, []
    with peep([ramp_long()]) as p:
        cpu = CpuSampler(p.pid)
        try:
            r = drive("spamkeys", p.pid, N, 0, timeout=90)
        finally:
            cpu.close()
        alive_after = True
    frames, _, m = read_lat()
    prog, _, drops = read_prog()
    src, heard = wav_data(ramp_long()), (LOGS / "heard.raw").read_bytes()
    for k in SPAM_KEYS:
        res[k] = spam_metrics(k, 20 if k.startswith("seek") else N - N % 2, m, frames, prog, drops, cpu, paused=(k == "pause"))
    res["quit"] = {"exit_ms": r["quit_ms"]}
    problems = []

    def pos(idx):
        k = src.find(heard[(idx - 4) * 4: idx * 4 + 12]) // 4 if idx >= 4 else 0
        assert k >= 0, "heard audio at frame %d is not from the file" % idx
        return k + 4 if idx >= 4 else 0
    # every seek key went through: 20 x 10 s, exactly
    for k, want in (("seek_fwd", 200.0), ("seek_back", -200.0)):
        i0, i1 = progress_at(prog, m["S_%s_BEGIN" % k]), progress_at(prog, m["S_%s_SETTLE" % k])
        jumped = (pos(i1) - pos(i0) - (i1 - i0)) / SR
        res[k]["net_seek_s"], res[k]["expected_s"] = jumped, want
        if abs(jumped - want) > 0.1:
            problems.append("%s moved %.2f s, not %.0f s: %s of 20 keys counted" % (k, jumped, want, round(abs(jumped) / 10)))
    # the audio between seeks is the file, sample for sample, through all of it
    end = progress_at(prog, m["S_seek_back_SETTLE"])
    cuts = sorted({0, *[d[2] for d in drops if 0 < d[2] < end]}) + [end]
    bad = 0
    for a, b in zip(cuts, cuts[1:]):
        if b - a < 4:
            continue
        k = src.find(heard[a * 4: a * 4 + 16]) // 4
        if heard[a * 4: b * 4] != src[k * 4: k * 4 + (b - a) * 4]:
            bad += 1
    res["seek_audio_stretches_garbled"] = bad
    if bad:
        problems.append("%d stretches of audio were garbled during seek spam" % bad)
    # next / previous, on the three-cover album
    with peep([album_dir()]) as p2:
        cpu2 = CpuSampler(p2.pid)
        try:
            drive("spamtracks", LOGS / "spam", timeout=60)
        finally:
            cpu2.close()
    frames2, _, m2 = read_lat()
    prog2, _, drops2 = read_prog()
    sizes2 = read_frames()
    for k in ("next", "prev"):
        res[k] = spam_metrics(k, 20, m2, frames2, prog2, drops2, cpu2)
        t0, t1 = m2["S_%s_BEGIN" % k], m2["S_%s_SETTLE" % k]
        # the middle cover is the wide one (1360x971): a burst that ends on the first or last track must not show it
        res[k]["intermediate_cover_frames"] = sum(1 for t, h, sz in sizes2 if t0 <= t <= t1 and sz == "1360x971")
        if res[k]["intermediate_cover_frames"]:
            problems.append("%s: %d frames showed a track the burst only passed through" % (k, res[k]["intermediate_cover_frames"]))
    for k, ok in (("next", lambda r_, g, b_: b_ > r_ + 60), ("prev", lambda r_, g, b_: r_ > b_ + 60)):
        im = Image.open(LOGS / ("spam_%s.ppm" % k)).convert("RGB")
        c = im.getpixel((im.width // 2, im.height // 2))
        res[k]["cover_colour_after"] = c
        if not ok(*c):
            problems.append("after 20 x %s the cover on screen is %s, not the %s track's" % (k, c, "last (blue)" if k == "next" else "first (red)"))
    for k in (*SPAM_KEYS, "next", "prev"):
        d = res[k]
        lag = d["last_frame_after_last_key_ms"]
        if lag is not None and lag > 300:
            problems.append("%s: still drawing %.0f ms after the last key" % (k, lag))
        if not d["audio_playing_at_end"]:
            problems.append("%s: the audio was not playing 300 ms after the spam" % k)
        stall = d["longest_audio_stall_ms"]
        if stall is not None and stall > 150:
            problems.append("%s: the audio stalled for %.0f ms" % (k, stall))
    if r["quit_ms"] > 100:
        problems.append("quit took %.0f ms after the spam" % r["quit_ms"])
    f = lambda v, fmt="%.1f": "-" if v is None else fmt % v
    lines.append("%-9s %5s %8s %9s %8s %7s %6s %10s %8s %9s" % (
        "key", "keys", "sent ms", "screen ms", "lag ms", "frames", "drops", "stall ms", "cpu ms", "cpu/key"))
    for k in (*SPAM_KEYS, "next", "prev"):
        d = res[k]
        lines.append("%-9s %5d %8s %9s %8s %7d %6d %10s %8s %9s" % (
            k, d["keys"], f(d["sent_ms"]), f(d["first_screen_ms"]), f(d["last_frame_after_last_key_ms"]), d["frames"],
            d["audio_drops"], f(d["longest_audio_stall_ms"]), f(d["cpu_ms"]), f(d["cpu_ms_per_key"], "%.3f")))
    lines.append("")
    lines.append("seek_fwd moved %.2f s of 200, seek_back %.2f s of -200; garbled audio stretches: %d; quit %.1f ms" % (
        res["seek_fwd"]["net_seek_s"], res["seek_back"]["net_seek_s"], bad, r["quit_ms"]))
    lines += ["PROBLEM: " + x for x in problems]
    write_report("spam", res, lines)
    assert not problems, "; ".join(problems) + " (see %s)" % (REPORTS / "spam.txt")
    return "every key spammed: backlog drained in %.0f ms at worst, audio clean, all seeks counted; details in %s" % (
        max(res[k]["last_frame_after_last_key_ms"] or 0 for k in (*SPAM_KEYS, "next", "prev")), REPORTS / "spam.json")


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
    """Volume keys never interrupt the sound: no queue drops, no stall, and the gain glides."""
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
    assert len(held) == 0, \
        "the audio queue was dropped %d times (a volume key must never interrupt the sound)" % len(held)
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
    # One key press is a step of up to 24/256 (voltab), which the mixer glides over a 1024-frame chunk: 1.5 per
    # 64 frames, 3 when two presses land in one chunk (key repeat is every 33 ms, a chunk is 23 ms), plus a
    # little estimation noise. A real, unglided step would be 24 at once.
    assert step < 6, "the gain jumped by %.1f/256 within 64 frames (it should glide): window %d of %d, gains around it %s" % (
        step, at_win, len(gains), [None if g is None else round(g, 1) for g in gains[max(0, at_win - 3): at_win + 5]])
    return "no queue drops in 3 s of key repeat, no stall, gain moves <= %.1f/256 per 64 frames" % step


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
        for t, q, after in REWINDS:           # a cut that took audio back: the next track starts just after the tail
            if t0 <= t <= t1:
                window = heard[after * 4: (after + 700) * 4]
                hit = next((i for i in range(3) if window.find(data[i][:16]) >= 0), None)
                if hit is not None:
                    out.append((hit, 0))
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
    objs = [ROOT / "build" / "dec.o", ROOT / "build" / "flac.o", ROOT / "build" / "wav.o",
            ROOT / "build" / "wavc.o"]
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
def wavc_decoder():
    """Compressed WAV (A-law, mu-law, IMA and Microsoft ADPCM) against independent models, and the workspace protocol."""
    need("ffmpeg")
    t = decoder_tools()
    r = subprocess.run([sys.executable, str(TESTS / "decoders" / "testwavc.py"), "--tool", str(t["peepdump"]),
                        "--seed", "1"], capture_output=True, text=True, timeout=600)
    out = (r.stdout + r.stderr).strip()
    assert r.returncode == 0 and " 0 failures" in r.stdout, out[-400:]
    seeds = BUILD / "seeds"
    seeds.mkdir(exist_ok=True)
    subprocess.run([sys.executable, str(TESTS / "decoders" / "testwavc.py"), "--gen", str(seeds)],
                   check=True, capture_output=True)
    ws = BUILD / "testwavc_ws"
    objs = [ROOT / "build" / n for n in ("dec.o", "flac.o", "wav.o", "wavc.o")]
    sp = TESTS / "decoders" / "testwavc_ws.c"
    if not ws.exists() or any(ws.stat().st_mtime <= p.stat().st_mtime for p in [sp, *objs]):
        subprocess.run(["gcc", "-w", "-O2", "-I", str(TESTS / "decoders"), "-o", str(ws), str(sp),
                        *map(str, objs)], check=True)
    files = sorted(str(f) for f in seeds.glob("c?.wav"))
    assert files, "testwavc.py --gen made no sample files"
    w = subprocess.run([str(ws), *files], capture_output=True, text=True)
    assert w.returncode == 0, (w.stdout + w.stderr).strip()[-300:]
    done = [l for l in r.stdout.splitlines() if " 0 failures" in l]
    return (done[-1] if done else r.stdout.strip().splitlines()[-1]).strip() + "; workspace protocol ok"


@check
def wavc_play():
    """Peep itself plays A-law, mu-law, IMA and Microsoft ADPCM WAV, sample for sample as the decoder gives them
    (the MP3 shim once took ADPCM files, which need scratch memory, and played silence)."""
    need("ffmpeg")
    t = decoder_tools()
    done = []
    for codec in ("pcm_alaw", "pcm_mulaw", "adpcm_ima_wav", "adpcm_ms"):
        f = ASSETS / ("play_%s.wav" % codec)
        if not f.exists():
            ASSETS.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                            "-ar", "22050", "-ac", "2", "-c:a", codec, str(f)], check=True)
        ref = subprocess.run([str(t["peepdump"]), str(f)], capture_output=True).stdout
        with peep([f]):
            time.sleep(1.5)
        heard = (LOGS / "heard.raw").read_bytes()
        n = min(len(heard), len(ref))
        assert n > 40000 and heard[:n] == ref[:n], "%s: Peep played %d bytes that differ from the decoder's output" % (codec, len(heard))
        done.append(codec.replace("pcm_", "").replace("adpcm_", "").replace("_wav", ""))
    return "played exactly the decoder's output: " + ", ".join(done)


def tone_wav(name, hz, seconds=10):
    """A loud sine (24000 of 32767, left and right the same) that starts at zero."""
    def make(p):
        import math
        n = SR * seconds
        d = array.array("h", [int(24000 * math.sin(2 * math.pi * hz * i / SR)) for i in range(n)])
        inter = array.array("h", bytes(n * 4))
        inter[0::2] = d
        inter[1::2] = d
        write_wav(p, inter.tobytes())
    return asset(name, make)


def check_clean_cut(A, B, heard, drops, marks, mark, expect_drop, latency=40):
    """The old track (A) ends at its quietest frame and the new one (B) follows: A is untouched before the cut,
    the tail is A's own audio, the last frame is near zero, and B is heard soon after `mark`."""
    e = heard.find(B[:128])
    assert e >= 0 and e % 4 == 0, "the new track never started"
    e //= 4
    left, right = struct.unpack("<hh", heard[(e - 1) * 4: e * 4])
    assert max(abs(left), abs(right)) <= 3000, "the old track was cut at %d/%d of 24000 (a click)" % (left, right)
    after = [d for d in drops if d[0] >= marks[mark]]
    assert bool(after) == expect_drop, "the queue was %sdropped" % ("not " if expect_drop else "")
    if after:
        c = after[0][2]
    else:
        assert REWINDS, "the audio was neither dropped nor taken back"
        c = [r for r in REWINDS if r[0] >= marks[mark]][0][2]
    assert heard[: (c - 3) * 4] == A[: (c - 3) * 4], "the audio before the cut was changed"
    # a sine repeats, so look for the tail only where it should be (within 2 frames of c)
    assert any(heard[c * 4: e * 4] == A[k * 4: k * 4 + (e - c) * 4] for k in range(c - 2, c + 3)), \
        "the tail of the old track was not its own audio"
    return max(abs(left), abs(right)), e


@check
def drop_clean_cut():
    """Dropping a file while one plays ends the old track at its quietest frame (no click) without dropping the
    audio queue, leaves its audio untouched, and starts the new file within 40 ms."""
    a, b = tone_wav("tone_a.wav", 440), tone_wav("tone_b.wav", 523)
    A, B = wav_data(a), wav_data(b)
    worst, latest = 0, 0
    for delay in (1500, 1517, 1531, 1549):          # different points of the wave
        with peep([a]):
            drive("dropfile", delay, b, timeout=60)
        prog, marks, drops = read_prog()
        heard = (LOGS / "heard.raw").read_bytes()
        w, e = check_clean_cut(A, B, heard, drops, marks, "DROP", expect_drop=False)
        start = next(t for t, p in prog if t >= marks["DROP"] and p > e)
        assert start - marks["DROP"] < 40, "the new file started %.0f ms after the drop" % (start - marks["DROP"])
        worst, latest = max(worst, w), max(latest, start - marks["DROP"])
    return "old track ended at |sample| <= %d of 24000, no queue drop, new one heard %.0f ms after the drop (4 timings)" % (worst, latest)


@check
def queue_append():
    """Dropping a file with Shift held adds it to the end of the playlist: the playing track is not interrupted
    (no queue drop, no rewind, its audio untouched) and the dropped one follows it without a gap."""
    a, b = tone_wav("tone_a3.wav", 440, 3), tone_wav("tone_b.wav", 523)
    A, B = wav_data(a), wav_data(b)
    with peep([a]):
        drive("dropfile", 1000, b, "shift", 4000, timeout=60)
    prog, marks, drops = read_prog()
    heard = (LOGS / "heard.raw").read_bytes()
    assert not [d for d in drops if d[0] >= marks["DROP"]] and not [r for r in REWINDS if r[0] >= marks["DROP"]], \
        "the playing track was interrupted by an append"
    assert heard[: len(A)] == A, "the playing track's audio was changed or cut"
    assert heard[len(A): len(A) + 128] == B[:128], "the appended track did not follow the first one"
    assert len(heard) > len(A) + 44100, "the appended track did not play"
    # and a drop without Shift still replaces
    with peep([a]):
        drive("dropfile", 1000, b, timeout=60)
    heard2 = (LOGS / "heard.raw").read_bytes()
    assert len(heard2) < len(A) + 44100 * 4 * 3 and heard2.find(B[:128]) < len(A) // 2, "a plain drop no longer replaces the list"
    return "Shift+drop queued the file after a 3 s track with no cut (%.1f s heard, B follows at frame %d)" % (len(heard) / 4 / SR, len(A) // 4)


@check
def text_size():
    """J makes the text larger and H smaller (50% to 200%): more text pixels after J, fewer after H, and it is quick."""
    need_pil()
    from PIL import Image
    with peep([long_mp3()]):
        drive("textsize", LOGS / "ts", timeout=60)

    def ink(name):
        im = Image.open(LOGS / ("ts_%s.ppm" % name)).convert("L")
        w, h = im.size
        px = im.crop((0, int(h * 0.55), w, h)).getdata()
        return sum(1 for v in px if v > 90)
    n0, nu, nd = ink("0"), ink("up"), ink("down")
    assert nu > n0 * 1.15, "after three J the text is not larger (%d -> %d bright pixels)" % (n0, nu)
    assert nd < n0 * 0.9, "after H the text is not smaller than the start (%d vs %d)" % (nd, n0)
    return "bright text pixels: %d at 100%%, %d after J x3, %d after H x8 (50%%)" % (n0, nu, nd)


@check
def skip_clean_cut():
    """Next in the middle of a track ends it the same way: no click, no queue drop, the next track follows."""
    a, b = tone_wav("tone_a.wav", 440), tone_wav("tone_b.wav", 523)
    A, B = wav_data(a), wav_data(b)
    worst = 0
    for delay in (1500, 1517, 1531):
        with peep([a, b]):
            drive("keyat", delay, "n", timeout=60)
        prog, marks, drops = read_prog()
        heard = (LOGS / "heard.raw").read_bytes()
        w, e = check_clean_cut(A, B, heard, drops, marks, "KEY", expect_drop=False)
        start = next(t for t, p in prog if t >= marks["KEY"] and p > e)
        assert start - marks["KEY"] < 60, "the next track started %.0f ms after the key" % (start - marks["KEY"])
        worst = max(worst, w)
    return "Next ended the track at |sample| <= %d of 24000, no queue drop" % worst


@check
def volume_instant():
    """A volume key is heard within 30 ms with no queue drop, and the audio around it is the file's, in order."""
    with peep([ramp_wav()]):
        drive("keyat", 1500, "down", timeout=60)
    prog, marks, drops = read_prog()
    assert not [d for d in drops if d[0] >= marks["KEY"]], "a volume key dropped the audio queue"
    assert REWINDS, "the volume key did not take the queued audio back"
    t, taken, c = [r for r in REWINDS if r[0] >= marks["KEY"]][0]
    assert t - marks["KEY"] < 30, "the audio was taken back %.0f ms after the key" % (t - marks["KEY"])
    src = array.array("h"); src.frombytes(wav_data(ramp_wav()))
    hd = array.array("h"); hd.frombytes((LOGS / "heard.raw").read_bytes())
    s_r, h_r = src[1::2], hd[1::2]                  # the right channel is random: it shows any repeat or skip
    def gain(lo, d=0):
        num = sum(h_r[k] * s_r[k + d] for k in range(lo, lo + 512))
        den = sum(s_r[k + d] * s_r[k + d] for k in range(lo, lo + 512))
        return 256 * num / den
    want = 231                                      # one step down from full volume
    g = gain(c + 1500)
    assert abs(g - want) < 4, "the gain after the key is %.1f/256, not %d" % (g, want)
    assert all(abs(gain(c + 1500, d) - want) > abs(g - want) for d in (-2, -1, 1, 2)), "a frame was repeated or skipped"
    return "gain %.0f/256 after the key, taken back %.0f ms after it, no queue drop" % (g, t - marks["KEY"])


@check
def rewind_fallback():
    """On a sound system that cannot take audio back (SIM_NO_REWIND, and the Windows build), a drop and a volume key
    behave as before: the queue is dropped for the drop, nothing changes for the volume key, audio stays intact."""
    a, b = tone_wav("tone_a.wav", 440), tone_wav("tone_b.wav", 523)
    A, B = wav_data(a), wav_data(b)
    with peep([a], SIM_NO_REWIND="1"):
        drive("dropfile", 1500, b, timeout=60)
    prog, marks, drops = read_prog()
    heard = (LOGS / "heard.raw").read_bytes()
    after = [d for d in drops if d[0] >= marks["DROP"]]
    assert after and not REWINDS, "without rewind the drop should flush the queue"
    e = heard.find(B[:128]) // 4
    assert e > 0, "the dropped file never started"
    assert heard[: (after[0][2] - 3) * 4] == A[: (after[0][2] - 3) * 4], "the audio before the drop was changed"
    with peep([ramp_wav()], SIM_NO_REWIND="1"):
        drive("keyat", 1500, "down", timeout=60)
    prog, marks, drops = read_prog()
    assert not REWINDS and not [d for d in drops if d[0] >= marks["KEY"]], "a volume key touched the queue"
    assert prog[-1][1] > 44100, "playback stopped"
    return "drop flushed the queue, volume key left it alone, audio intact"


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
    if not (seeds / "c0.wav").exists():
        subprocess.run([sys.executable, str(TESTS / "decoders" / "testwavc.py"), "--gen", str(seeds)],
                       capture_output=True)
    files += sorted(str(f) for f in seeds.glob("c?.wav"))
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


# ---------------------------------------------------------------------- Wayland
# The Wayland build (build/peep-wayland) on a real compositor: sway, headless. tests/wl.py
# plays the user through a virtual pointer and keyboard, and drags as a file manager does.
PEEP_WL = Path(os.environ.get("PEEP_WL_BIN") or ROOT / "build" / "peep-wayland")
XRD = BUILD / "xrd"


PEEP_WL_BARE = BUILD / "peep-wayland-bare"


def bare_build():
    """peep-wayland assembled to ignore the decoration and cursor-shape protocols, as on a
    compositor that has neither (GNOME): no title bar, so Peep's own resize borders and arrow."""
    src = ROOT / "src" / "wayland.asm"
    if not PEEP_WL_BARE.exists() or PEEP_WL_BARE.stat().st_mtime < max(src.stat().st_mtime, PEEP_WL.stat().st_mtime):
        obj = BUILD / "wayland_bare.o"
        subprocess.run(["nasm", "-f", "elf64", "-DBARE", "-I" + str(ROOT / "src") + "/", str(src),
                        "-o", str(obj)], check=True)
        b = ROOT / "build"
        subprocess.run(["gcc", "-no-pie", "-o", str(PEEP_WL_BARE), str(obj),
                        *[str(b / (n + ".o")) for n in ("core", "meta", "gfx", "linux_wl", "dec", "flac",
                                                        "wav", "wavc", "codecs")],
                        "-lasound", "-lm"], check=True)
    return PEEP_WL_BARE


class Wayland:
    def __init__(self, args, binary=None):
        need("sway", "grim")
        if not PEEP_WL.exists():
            raise Skip("no build/peep-wayland (make wayland)")
        binary = binary or PEEP_WL
        shutil.rmtree(XRD, ignore_errors=True)
        XRD.mkdir(parents=True, mode=0o700)
        cfg = XRD / "sway.cfg"
        cfg.write_text('output HEADLESS-1 resolution 1600x1200\n'
                       'for_window [app_id="peep"] floating enable%s\n'
                       'for_window [app_id="peepsrc"] floating enable, move position 0 0\n' % (", border none" if binary != PEEP_WL else ""))
        self.env = env(XDG_RUNTIME_DIR=str(XRD), WLR_BACKENDS="headless", WLR_RENDERER="pixman",
                       WLR_LIBINPUT_NO_DEVICES="1")
        self.env.pop("DISPLAY", None)
        self.env.pop("WAYLAND_DISPLAY", None)
        quiet = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        noshim = {k: v for k, v in self.env.items() if k != "LD_PRELOAD"}
        self.procs = [subprocess.Popen(["sway", "-c", str(cfg)], env=noshim, **quiet)]
        try:
            for _ in range(100):
                socks = [f for f in XRD.glob("wayland-*") if not f.name.endswith(".lock")]
                if socks and list(XRD.glob("sway-ipc*")):
                    break
                time.sleep(0.05)
            else:
                raise Skip("sway did not start (headless)")
            time.sleep(0.5)                          # until all its globals are up
            self.env["WAYLAND_DISPLAY"] = noshim["WAYLAND_DISPLAY"] = socks[0].name
            noshim["SWAYSOCK"] = str(next(XRD.glob("sway-ipc*")))
            self.noshim = noshim
            reset_logs()
            self.peep = subprocess.Popen([str(binary), *map(str, args)], env=self.env, **quiet)
            self.procs.append(self.peep)
            self.user = subprocess.Popen([sys.executable, str(TESTS / "wl.py")], env=noshim, text=True,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         start_new_session=True)
            self.procs.append(self.user)
            assert self.user.stdout.readline().startswith("ok"), "tests/wl.py did not start"
            for _ in range(60):
                if self.geo():
                    break
                time.sleep(0.05)
            else:
                raise AssertionError("Peep's window did not appear")
            time.sleep(0.4)
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def close(self):
        for p in reversed(self.procs):
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()

    def do(self, cmd, wait=0.35):
        """One command for tests/wl.py, then time for Peep to react."""
        self.user.stdin.write(cmd + "\n")
        self.user.stdin.flush()
        r = self.user.stdout.readline().strip()
        assert r.startswith("ok"), "wl.py %s: %s" % (cmd, r or "died")
        time.sleep(wait)
        return r

    def geo(self):
        """Peep's window: (x, y, w, h, fullscreen) of its contents, or None."""
        tree = json.loads(subprocess.run(["swaymsg", "-t", "get_tree"], env=self.noshim,
                                         capture_output=True, text=True).stdout or "{}")

        def walk(n):
            if n.get("app_id") == "peep":
                r, w = n["rect"], n["window_rect"]
                return r["x"] + w["x"], r["y"] + w["y"], w["width"], w["height"], n["fullscreen_mode"]
            for c in n.get("nodes", []) + n.get("floating_nodes", []):
                g = walk(c)
                if g:
                    return g
        return walk(tree)

    def shot(self, cursor=False):
        data = subprocess.run(["grim", *(["-c"] if cursor else []), "-t", "ppm", "-"], env=self.noshim, capture_output=True).stdout
        head = data.split(b"\n", 3)
        w, h = map(int, head[1].split())
        return w, h, head[3]

    def view(self):
        """The pixels of Peep's window, without the compositor's frame around it."""
        x, y, ww, hh, _ = self.geo()
        w, h, px = self.shot()
        return b"".join(px[(r * w + x) * 3:(r * w + x + ww) * 3] for r in range(y, y + hh))

    def colour(self, at=None):
        """The colour at a screen point (default: the middle of Peep's window), by name."""
        if at is None:
            x, y, w, h, _ = self.geo()
            at = (x + w // 2, y + h // 2)
        w, h, px = self.shot()
        r, g, b = px[(at[1] * w + at[0]) * 3:][:3]
        if max(r, g, b) < 40:
            return "black"
        return {r: "red", g: "green", b: "blue"}[max(r, g, b)]


def shape(g):
    return g[2] / g[3]


@check
def wayland_keys():
    """Wayland build on sway: every key works, found in the keymap by name (also on AZERTY); the window takes each cover's shape; fullscreen and back; Q quits."""
    with Wayland([album_dir()]) as w:
        g = w.geo()
        assert abs(shape(g) - 1) < 0.01 and g[3] > 900, "first cover 1400x1400, window %dx%d" % g[2:4]
        seen = [w.colour()]
        for k in ("n", "Next", "p", "Prior"):
            w.do("key " + k)
            seen.append(w.colour())
        assert seen == ["red", "green", "blue", "green", "red"], "covers shown: %s" % seen
        w.do("key n")
        g = w.geo()
        assert abs(shape(g) - 1.4) < 0.01, "cover 1400x1000, window %dx%d" % g[2:4]
        w.do("key S-Tab")
        assert w.colour() == "black", "Shift+Tab did not blank the window"
        w.do("key S-Tab")
        assert w.colour() == "green", "Shift+Tab did not bring the cover back"
        w.do("key f", 0.6)
        g = w.geo()
        assert g[4] == 1 and g[2:4] == (1600, 1200), "F: not fullscreen (%s)" % (g,)
        assert w.colour((800, 20)) == "black" and w.colour((800, 600)) == "green", "fullscreen frame is wrong"
        w.do("key Escape", 0.6)
        g = w.geo()
        assert g[4] == 0 and abs(shape(g) - 1.4) < 0.01, "Escape: %s" % (g,)
        w.do("key Escape")
        assert w.geo()[4] == 0, "Escape outside fullscreen did something"
        # a held key repeats (on Wayland that is the client's job): one P restarts the
        # track or goes back one, a held P reaches the first
        w.do("hold p 1500")
        assert w.colour() == "red", "a held key did not repeat"
        if have("xkbcli"):
            w.do("layout fr", 0.5)        # AZERTY: Q is where A is on QWERTY
            w.do("key n")
            assert w.colour() == "green", "N not found on the fr layout"
            w.do("key a")                 # the key that is Q on QWERTY
            assert w.peep.poll() is None, "the QWERTY position of Q quit on AZERTY"
        w.do("key q")
        assert w.peep.wait(timeout=2) == 0, "Q did not quit"
    return "keys, cover shapes, fullscreen, quit"


@check
def wayland_pointer():
    """Wayland build on sway: controls show only under the pointer and go when it leaves; a click on the art drags the window; in fullscreen the controls return on movement."""
    with Wayland([album_dir()]) as w:
        x, y, ww, hh, _ = w.geo()
        low = (x + ww // 2, y + hh - hh // 8)       # in the controls
        w.do("ptr 5 5")
        w.do("key Tab", 0.8)
        assert w.colour(low) == "red", "controls visible with the pointer outside"
        off = w.view()
        w.do("ptr %d %d" % (x + ww // 2, y + hh // 2))
        on = w.view()
        diff = sum(1 for i in range(0, len(on), 997) if on[i] != off[i])
        assert diff > 20, "controls not shown with the pointer inside"
        w.do("ptr 5 5", 0.9)
        assert w.view() == off, "controls did not go away when the pointer left"
        # drag the window by the art
        w.do("ptr %d %d" % (x + ww // 2, y + hh // 3))
        w.do("down", 0.2)
        w.do("ptr %d %d" % (x + ww // 2 - 150, y + hh // 3 + 40), 0.2)
        w.do("up")
        g = w.geo()
        assert (g[0], g[1]) == (x - 150, y + 40), "window at %s after a drag from %s" % (g[:2], (x, y))
        # fullscreen: controls fade after 2 s of stillness, return on movement
        w.do("key f", 0.6)
        w.do("ptr 800 600", 3.2)
        still = w.view()
        w.do("ptr 810 610", 0.3)
        moved = w.view()
        diff = sum(1 for i in range(0, len(still), 997) if still[i] != moved[i])
        assert diff > 20, "fullscreen: controls did not return on movement"
        assert w.peep.poll() is None, "Peep died"
    return "hover, window drag, fullscreen controls and pointer"


@check
def wayland_bare():
    """Wayland build on a compositor that draws no title bar and names no cursors: Peep sets its own arrow, and dragging a border resizes the window in the cover's shape."""
    with Wayland([album_dir() / "t1.mp3"], bare_build()) as w:      # a 1400x1000 cover
        x, y, ww, hh, _ = w.geo()
        w.do("ptr %d %d" % (x + ww // 2, y + hh // 2))
        w.do("ptr %d %d" % (x + ww - 2, y + hh // 2))
        w.do("down", 0.2)
        for i in range(1, 6):
            w.do("ptr %d %d" % (x + ww - 2 - 80 * i, y + hh // 2), 0.05)
        w.do("up")
        g = w.geo()
        assert abs(g[2] - (ww - 400)) <= 4, "width %d after dragging the right border in by 400 (was %d)" % (g[2], ww)
        assert abs(shape(g) - 1.4) < 0.01, "resized to %dx%d, not the cover's shape" % g[2:4]
        assert w.colour() == "green" and w.peep.poll() is None
    return "own arrow, border resize %dx%d -> %dx%d" % (ww, hh, g[2], g[3])


@check
def wayland_drop():
    """Wayland build on sway: a file dragged onto the window (text/uri-list, as a file manager sends it, %-escapes and all) replaces the queue and plays."""
    with Wayland([album_dir() / "t0.mp3"]) as w:
        assert w.colour() == "red"
        x, y, ww, hh, _ = w.geo()
        spaced = ASSETS / "drop me.mp3"
        shutil.copy(album_dir() / "t2.mp3", spaced)
        r = w.do("drag %d %d file://%s" % (x + ww // 2, y + hh // 2,
                                             str(spaced).replace(" ", "%20")), 0.8)
        assert "sent" in r, "the drop was not accepted (%s)" % r
        assert w.colour() == "blue", "the dropped file's cover is not shown"
        r = w.do("drag %d %d file://%s" % (x + ww // 2, y + hh // 2, album_dir()), 0.8)
        assert w.colour() == "red", "a dropped folder did not play from its first track"
    return "file and folder drops play"


# ----------------------------------------------------------------------- driver
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", help="run only these checks")
    ap.add_argument("--list", action="store_true", help="list the checks")
    a = ap.parse_args()
    if a.list:
        for c in CHECKS:
            print("%-18s %s" % (c.__name__, c.__doc__))
        for g, members in GROUPS.items():
            print("\ngroup %-12s %s" % (g, ", ".join(members)))
        return 0
    names = [n for name in a.names for n in GROUPS.get(name, [name])]
    todo = [c for c in CHECKS if not names or c.__name__ in names]
    unknown = set(names) - {c.__name__ for c in CHECKS}
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
