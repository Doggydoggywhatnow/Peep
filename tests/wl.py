#!/usr/bin/env python3
"""Plays the user on a Wayland compositor (sway, headless), for the Wayland checks in run.py.

It is a small Wayland client: a virtual pointer and a virtual keyboard (the wlroots
protocols), and a little window of its own to start a real drag from, as a file manager
does. Commands come one per line on stdin; each is answered with "ok" on stdout:

    ptr X Y            move the pointer to X,Y on the screen
    down | up          left button
    key NAME           press and release a key (NAME as in KEYS; "S-Tab" holds Shift)
    hold NAME MS       hold a key down for MS milliseconds
    drag X Y TEXT      drag TEXT (a text/uri-list, \\n for newlines) from our window to X,Y
    layout NAME        use that xkb layout (needs xkbcli); keys are then found by evdev code

The keyboard's first keymap puts every key on a made-up key code, so Peep has to find the
keys in the keymap by name, not by position.
"""
import os
import select
import socket
import struct
import subprocess
import sys
import time

KEYS = ["n", "p", "g", "v", "f", "q", "space", "Left", "Right", "Up", "Down", "Next", "Prior",
        "Tab", "Escape", "a"]
# where those keys are on a real keyboard (evdev codes), for `layout`
EVDEV = dict(space=57, Left=105, Right=106, Up=103, Down=108, Next=109, Prior=104, Tab=15,
             Escape=1)
SCREEN = (1600, 1200)


def keymap_text():
    codes = "".join("<K%d> = %d;\n" % (i, i + 40) for i in range(len(KEYS)))
    syms = "".join("key <K%d> {[%s]};\n" % (i, k) for i, k in enumerate(KEYS))
    return ('xkb_keymap {\nxkb_keycodes "(unnamed)" {\nminimum = 8;\nmaximum = 255;\n' + codes +
            '};\nxkb_types "(unnamed)" { include "complete" };\n'
            'xkb_compatibility "(unnamed)" { include "complete" };\n'
            'xkb_symbols "(unnamed)" {\n' + syms + '};\n};\n')


class Wl:
    def __init__(self):
        path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ["WAYLAND_DISPLAY"])
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.next = 2
        self.buf = b""
        self.fds = []
        self.handlers = {}       # object id -> fn(opcode, payload)
        self.globals = {}        # interface -> (name, version)
        self.reg = self.new()
        self.handlers[self.reg] = self.on_global
        self.send(1, 1, struct.pack("I", self.reg))
        self.roundtrip()

    def new(self):
        i = self.next
        self.next += 1
        return i

    def send(self, obj, op, payload=b"", fds=()):
        msg = struct.pack("IHH", obj, op, 8 + len(payload)) + payload
        if fds:
            self.s.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("i", *fds))])
        else:
            self.s.sendall(msg)

    @staticmethod
    def string(t):
        b = t.encode() + b"\0"
        return struct.pack("I", len(b)) + b + b"\0" * (-len(b) % 4)

    def on_global(self, op, p):
        if op == 0:
            name, n = struct.unpack_from("II", p)
            iface = p[8:8 + n - 1].decode()
            ver = struct.unpack_from("I", p, 8 + (n + 3 & ~3))[0]
            self.globals.setdefault(iface, (name, ver))

    def bind(self, iface, ver):
        name, have = self.globals[iface]
        i = self.new()
        self.send(self.reg, 0, struct.pack("I", name) + self.string(iface) +
                  struct.pack("II", min(ver, have), i))
        return i

    def pump(self, secs):
        end = time.time() + secs
        while True:
            left = end - time.time()
            if left < 0 or not select.select([self.s], [], [], left)[0]:
                return
            data, anc, _, _ = self.s.recvmsg(65536, 4096)
            if not data:
                sys.exit("compositor closed the connection")
            for _, _, d in anc:
                self.fds += struct.unpack("%di" % (len(d) // 4), d)
            self.buf += data
            while len(self.buf) >= 8:
                obj, op, size = struct.unpack_from("IHH", self.buf)
                if len(self.buf) < size:
                    break
                p, self.buf = self.buf[8:size], self.buf[size:]
                if obj == 1 and op == 0:
                    sys.exit("protocol error: %r" % p)
                h = self.handlers.get(obj)
                if h:
                    h(op, p)

    def roundtrip(self):
        cb = self.new()
        done = []
        self.handlers[cb] = lambda op, p: done.append(1)
        self.send(1, 0, struct.pack("I", cb))
        while not done:
            self.pump(0.05)


class User:
    def __init__(self):
        w = self.w = Wl()
        self.seat = w.bind("wl_seat", 5)
        vpm = w.bind("zwlr_virtual_pointer_manager_v1", 1)   # (ids must be used in the order made)
        self.vp = w.new()
        w.send(vpm, 0, struct.pack("II", self.seat, self.vp))
        vkm = w.bind("zwp_virtual_keyboard_manager_v1", 1)
        self.vk = w.new()
        w.send(vkm, 0, struct.pack("II", self.seat, self.vk))
        self.codes = {k: i + 32 for i, k in enumerate(KEYS)}   # evdev = xkb code - 8
        self.keymap(keymap_text())
        self.win = None
        w.roundtrip()

    def ms(self):
        return int(time.time() * 1000) & 0x7fffffff

    def keymap(self, text):
        data = text.encode() + b"\0"
        fd = os.memfd_create("keymap")
        os.write(fd, data)
        self.w.send(self.vk, 0, struct.pack("II", 1, len(data)), [fd])
        os.close(fd)

    def layout(self, name):
        text = subprocess.run(["xkbcli", "compile-keymap", "--layout", name], check=True,
                              capture_output=True, text=True).stdout
        self.keymap(text)
        # letters by what the layout calls them: find "key <X> { [ q" and <X>'s number
        import re
        num = {m.group(1): int(m.group(2)) for m in re.finditer(r"<(\w+)>\s*=\s*(\d+);", text)}
        self.codes = dict(EVDEV)
        for m in re.finditer(r"key\s+<(\w+)>\s*\{[^;]*?\[\s*(\w+)", text):
            if len(m.group(2)) == 1 and m.group(2) not in self.codes:
                self.codes[m.group(2)] = num[m.group(1)] - 8

    def ptr(self, x, y):
        self.w.send(self.vp, 1, struct.pack("IIIII", self.ms(), x, y, *SCREEN))
        self.w.send(self.vp, 4)

    def button(self, state):
        self.w.send(self.vp, 2, struct.pack("III", self.ms(), 0x110, state))
        self.w.send(self.vp, 4)

    def key(self, name, hold=0.0):
        shift = name.startswith("S-")
        code = self.codes[name[2:] if shift else name]
        if shift:
            self.w.send(self.vk, 2, struct.pack("IIII", 1, 0, 0, 0))
        self.w.send(self.vk, 1, struct.pack("III", self.ms(), code, 1))
        self.w.pump(hold)
        self.w.send(self.vk, 1, struct.pack("III", self.ms(), code, 0))
        if shift:
            self.w.send(self.vk, 2, struct.pack("IIII", 0, 0, 0, 0))

    # ---- a window of our own, to drag from (sway puts it at 0,0: see run.py)
    def window(self):
        w = self.w
        comp, shm, wm = w.bind("wl_compositor", 4), w.bind("wl_shm", 1), w.bind("xdg_wm_base", 1)
        self.ddm = w.bind("wl_data_device_manager", 3)
        w.handlers[wm] = lambda op, p: w.send(wm, 3, p)                      # ping -> pong
        self.surf, xs, top = w.new(), w.new(), w.new()
        w.send(comp, 0, struct.pack("I", self.surf))
        w.send(wm, 2, struct.pack("II", xs, self.surf))
        w.send(xs, 1, struct.pack("I", top))
        w.send(top, 3, w.string("peepsrc"))
        conf = []
        w.handlers[xs] = lambda op, p: (w.send(xs, 4, p), conf.append(1))
        w.send(self.surf, 6)
        while not conf:
            w.pump(0.05)
        fd = os.memfd_create("buf")
        os.ftruncate(fd, 64 * 64 * 4)
        pool, buf = w.new(), w.new()
        w.send(shm, 0, struct.pack("II", pool, 64 * 64 * 4), [fd])
        os.close(fd)
        w.send(pool, 0, struct.pack("IiiiiI", buf, 0, 64, 64, 256, 1))
        w.send(self.surf, 1, struct.pack("Iii", buf, 0, 0))
        w.send(self.surf, 6)
        self.pointer = w.new()
        self.press = []
        w.handlers[self.pointer] = lambda op, p: op == 3 and self.press.append(struct.unpack_from("I", p)[0])
        w.send(self.seat, 0, struct.pack("I", self.pointer))
        self.dd = w.new()
        w.send(self.ddm, 1, struct.pack("II", self.dd, self.seat))
        w.pump(0.5)
        self.win = True

    def drag(self, x, y, text):
        w = self.w
        if not self.win:
            self.window()
        self.ptr(32, 32)
        w.pump(0.2)
        self.press.clear()
        self.button(1)
        end = time.time() + 2
        while not self.press and time.time() < end:
            w.pump(0.05)
        if not self.press:
            return "error: our window did not get the press"
        src = w.new()
        w.send(self.ddm, 0, struct.pack("I", src))
        w.send(src, 0, w.string("text/uri-list"))
        w.send(src, 2, struct.pack("I", 1))                                  # set_actions(copy)
        result = []

        def on_src(op, p):
            if op == 1:                                                      # send(mime, fd)
                fd = w.fds.pop(0)
                os.write(fd, text.encode())
                os.close(fd)
                result.append("sent")
            elif op == 2:
                result.append("cancelled")
            elif op == 4:
                result.append("finished")
        w.handlers[src] = on_src
        w.send(self.dd, 0, struct.pack("IIII", src, self.surf, 0, self.press[0]))
        for i in range(1, 11):                                               # a drag, not a jump
            self.ptr(32 + (x - 32) * i // 10, 32 + (y - 32) * i // 10)
            w.pump(0.03)
        w.pump(0.2)
        self.button(0)
        end = time.time() + 2
        while "sent" not in result and "cancelled" not in result and time.time() < end:
            w.pump(0.05)
        w.pump(0.2)
        return "ok " + ",".join(result)


def main():
    u = User()
    print("ok", flush=True)
    for line in sys.stdin:
        a = line.split()
        out = "ok"
        if not a:
            continue
        if a[0] == "ptr":
            u.ptr(int(a[1]), int(a[2]))
        elif a[0] == "down":
            u.button(1)
        elif a[0] == "up":
            u.button(0)
        elif a[0] == "key":
            u.key(a[1], 0.03)
        elif a[0] == "hold":
            u.key(a[1], int(a[2]) / 1000)
        elif a[0] == "layout":
            u.layout(a[1])
        elif a[0] == "drag":
            out = u.drag(int(a[1]), int(a[2]), line.split(None, 3)[3].strip().replace("\\n", "\r\n") + "\r\n")
        u.w.pump(0.05)
        print(out, flush=True)


if __name__ == "__main__":
    main()
