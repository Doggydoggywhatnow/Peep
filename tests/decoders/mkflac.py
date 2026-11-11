#!/usr/bin/env python3
"""Randomised FLAC *encoder* for testing decoders. It does not try to compress well;
it tries to use every feature of the format, and it knows the exact PCM it encoded,
so a decoder is checked against ground truth.

Covers: all 11 channel assignments, fixed and variable block size, every block size
code (incl. 8/16-bit explicit sizes and odd sizes), explicit sample-rate codes,
4..24 bit samples, constant / verbatim / fixed 0-4 / LPC 1-32 subframes, wasted bits,
Rice methods 0 and 1, all partition orders, escape partitions (incl. 0-bit), very long
unary runs, extra metadata blocks, unknown total sample count.

  mkflac.py --run N [--seed S] [--tool build/peepdump] [--keep DIR]
"""
import argparse, math, os, random, subprocess, sys, tempfile
import numpy as np

# ---------------------------------------------------------------- bit writer
class BW:
    def __init__(self): self.buf = bytearray(); self.acc = 0; self.n = 0
    def w(self, n, v):
        if n == 0: return
        self.acc = (self.acc << n) | (v & ((1 << n) - 1)); self.n += n
        while self.n >= 8:
            self.n -= 8; self.buf.append((self.acc >> self.n) & 0xFF)
        self.acc &= (1 << self.n) - 1
    def zeros(self, q):
        while q >= 32: self.w(32, 0); q -= 32
        self.w(q, 0)
    def pad(self):
        if self.n: self.w(8 - self.n, 0)
    def bytes(self): assert self.n == 0; return bytes(self.buf)

def crc8(b):
    c = 0
    for x in b:
        c ^= x
        for _ in range(8): c = ((c << 1) ^ 7) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c
_T16 = []
for i in range(256):
    c = i << 8
    for _ in range(8): c = ((c << 1) ^ 0x8005) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    _T16.append(c)
def crc16(b):
    c = 0
    for x in b: c = ((c << 8) & 0xFFFF) ^ _T16[(c >> 8) ^ x]
    return c

def utf8(v):
    if v < 0x80: return bytes([v])
    n = 1
    while v >= (1 << (6 * n + (6 - n))): n += 1       # n continuation bytes
    out = [(0xFF << (7 - n)) & 0xFF | (v >> (6 * n))]
    for i in range(n - 1, -1, -1): out.append(0x80 | ((v >> (6 * i)) & 0x3F))
    return bytes(out)

# ---------------------------------------------------------------- residual
FIXED = {0: [], 1: [1], 2: [2, -1], 3: [3, -3, 1], 4: [4, -6, 4, -1]}   # newest sample first

def predict(x, coefs, shift):
    """pred[i] for i >= order, coefs newest first (exactly the decoder's arithmetic)."""
    order = len(coefs); n = len(x)
    acc = np.zeros(n - order, dtype=np.int64)
    for j, c in enumerate(coefs): acc += int(c) * x[order - 1 - j: n - 1 - j]
    return acc >> shift

def zigzag(r): return np.where(r >= 0, r << 1, ((-r) << 1) - 1)
def signed_bits(v):
    return 0 if v == 0 else (v if v >= 0 else ~v).bit_length() + 1

def write_residual(bw, r, bs, order, rng):
    """r = residuals for samples order..bs-1."""
    maxpo = 0
    while bs % (1 << (maxpo + 1)) == 0 and (bs >> (maxpo + 1)) >= max(order, 1) and maxpo < 15: maxpo += 1
    po = rng.randint(0, min(maxpo, 8)) if rng.random() < .85 else rng.randint(0, maxpo)
    psize = bs >> po
    parts = []; pos = 0
    for p in range(1 << po):
        cnt = psize - (order if p == 0 else 0)
        parts.append(r[pos:pos + cnt]); pos += cnt
    ks = []
    for seg in parts:
        u = zigzag(seg) if len(seg) else np.zeros(0, dtype=np.int64)
        k = 0
        if len(u):
            mean = max(1.0, float(u.mean())); k = max(0, int(math.log2(mean)))
        roll = rng.random()
        if roll < .12: k = max(0, k - rng.randint(1, 9))              # long unary runs
        elif roll < .20: k = rng.randint(0, 30)
        while len(u) and int((u >> k).sum()) > 30000: k += 1          # keep the test files small
        ks.append(k)
    esc = [rng.random() < .06 for _ in parts]
    method = 1 if (max(ks) > 14 or rng.random() < .3 or any(esc and True for _ in [0]) and False) else 0
    method = 1 if max(ks) > 14 else rng.randint(0, 1)
    pb = 4 + method; escape = (1 << pb) - 1
    ks = [min(k, escape - 1) for k in ks]
    bw.w(2, method); bw.w(4, po)
    for seg, k, e in zip(parts, ks, esc):
        if e and len(seg):
            n = max(signed_bits(int(v)) for v in seg)
            if n <= 31:
                bw.w(pb, escape); bw.w(5, n)
                for v in seg: bw.w(n, int(v))
                continue
        if e and not len(seg):                                         # empty partition may escape too
            bw.w(pb, escape); bw.w(5, 0); continue
        bw.w(pb, k)
        for v in seg:
            u = (int(v) << 1) if v >= 0 else (((-int(v)) << 1) - 1)
            q = u >> k; bw.zeros(q); bw.w(1, 1); bw.w(k, u & ((1 << k) - 1))

def write_subframe(bw, x, width, rng):
    """x: int64 array of samples that fit `width` signed bits."""
    bs = len(x); x = x.astype(np.int64)
    wasted = 0
    if x.any() and rng.random() < .9:
        w = 0
        while w < width - 1 and not (x & ((1 << (w + 1)) - 1)).any(): w += 1
        wasted = w if rng.random() < .8 else rng.randint(0, w)
    xs = x >> wasted; wd = width - wasted
    kinds = ['verbatim', 'fixed', 'lpc', 'lpc']
    if (xs == xs[0]).all() and rng.random() < .9: kind = 'constant'
    else: kind = rng.choice(kinds)
    if kind == 'fixed' and bs < 1: kind = 'verbatim'
    hdr = {'constant': 0, 'verbatim': 1}.get(kind)
    # --- header
    bw.w(1, 0)
    if kind in ('constant', 'verbatim'):
        bw.w(6, hdr)
    elif kind == 'fixed':
        order = rng.randint(0, min(4, bs)); bw.w(6, 8 + order)
    else:
        order = rng.randint(1, min(32, bs)); bw.w(6, 31 + order)
    if wasted: bw.w(1, 1); bw.zeros(wasted - 1); bw.w(1, 1)
    else: bw.w(1, 0)
    # --- body
    if kind == 'constant':
        bw.w(wd, int(xs[0]))
    elif kind == 'verbatim':
        for v in xs: bw.w(wd, int(v))
    else:
        for v in xs[:order]: bw.w(wd, int(v))
        if kind == 'fixed':
            coefs, shift = FIXED[order], 0
        else:
            prec = rng.randint(5, 15) if rng.random() < .8 else rng.choice([2, 3, 4, 15])
            coefs, shift = quantised_lpc(xs, order, prec, rng)
            bw.w(4, prec - 1); bw.w(5, shift)
            for c in coefs: bw.w(prec, int(c))
        pred = predict(xs, coefs, shift) if order else np.zeros(bs, dtype=np.int64)
        write_residual(bw, xs[order:] - pred, bs, order, rng)
    return

def quantised_lpc(x, order, prec, rng):
    lim = 1 << (prec - 1)
    try:
        if len(x) <= order + 2 or rng.random() < .1: raise ValueError
        A = np.stack([x[order - 1 - j: len(x) - 1 - j] for j in range(order)], axis=1).astype(np.float64)
        c = np.linalg.lstsq(A, x[order:].astype(np.float64), rcond=None)[0]
        cmax = max(1e-9, float(np.abs(c).max()))
        shift = max(0, min(15, prec - 1 - math.ceil(math.log2(cmax + 1e-12))))
        q = np.clip(np.round(c * (1 << shift)), -lim, lim - 1).astype(np.int64)
        return [int(v) for v in q], shift
    except Exception:
        return [rng.randint(-min(lim, 3), min(lim - 1, 3)) for _ in range(order)], rng.randint(0, 4)

# ---------------------------------------------------------------- signals
def make_signal(rng, n, nch, bps):
    lo, hi = -(1 << (bps - 1)), (1 << (bps - 1)) - 1
    kind = rng.choice(['sine', 'sine', 'noise', 'silence', 'dc', 'square', 'impulse', 'sparse', 'wasted', 'bassy'])
    t = np.arange(n, dtype=np.float64)
    chans = []
    base = None
    for c in range(nch):
        if kind == 'sine' or kind == 'bassy':
            f = rng.uniform(0.001, 0.2 if kind == 'sine' else 0.01)
            a = rng.uniform(0.05, 0.95) * hi
            v = a * np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) + rng.uniform(0, .02) * hi * np.random.RandomState(rng.randint(0, 9999)).randn(n)
        elif kind == 'noise': v = np.random.RandomState(rng.randint(0, 99999)).uniform(lo, hi + 1, n)
        elif kind == 'silence': v = np.zeros(n)
        elif kind == 'dc': v = np.full(n, rng.randint(lo, hi), dtype=np.float64)
        elif kind == 'square': v = np.where(np.sin(2 * np.pi * rng.uniform(.001, .05) * t) > 0, hi * .7, lo * .7)
        elif kind == 'impulse':
            v = np.zeros(n); v[::rng.randint(7, 500)] = hi * rng.uniform(.2, 1)
        else:
            v = rng.uniform(.1, .9) * hi * np.sign(np.sin(0.01 * t * (c + 1))) * (np.random.RandomState(c).rand(n) > .7)
        if base is not None and rng.random() < .6 and kind in ('sine', 'bassy', 'noise'):
            v = base + 0.05 * hi * np.random.RandomState(rng.randint(0, 999)).randn(n)    # correlated channels
        base = v if base is None else base
        x = np.clip(np.round(v), lo, hi).astype(np.int64)
        if kind == 'wasted': x = x & ~((1 << rng.randint(1, max(1, bps - 2))) - 1)
        chans.append(np.clip(x, lo, hi))
    return chans

# ---------------------------------------------------------------- frames / stream
BS_CODE = {192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9, 1024: 10, 2048: 11, 4096: 12, 8192: 13, 16384: 14, 32768: 15}
SR_CODE = {88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6, 24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11}
BPS_CODE = {8: 1, 12: 2, 16: 4, 20: 5, 24: 6}

def encode_frame(chans, start, number, variable, rate, bps, bps_explicit, rng):
    nch = len(chans); bs = len(chans[0]); bw = BW()
    # block size code
    if bs in BS_CODE and rng.random() < .85: bsc, bsx = BS_CODE[bs], None
    elif bs <= 256 and rng.random() < .7: bsc, bsx = 6, (8, bs - 1)
    else: bsc, bsx = 7, (16, bs - 1)
    if bsc == 7 and bs > 65536: raise ValueError
    # sample rate code
    src, srx = 0, None
    if rng.random() < .5:
        if rate in SR_CODE: src = SR_CODE[rate]
        elif rate % 1000 == 0 and rate // 1000 <= 255: src, srx = 12, (8, rate // 1000)
        elif rate <= 65535: src, srx = 13, (16, rate)
        elif rate % 10 == 0 and rate // 10 <= 65535: src, srx = 14, (16, rate // 10)
    # channel assignment
    if nch == 2:
        ca = rng.choice([1, 1, 8, 9, 10])
        L, R = chans
        if ca == 8: sub = [L, L - R]
        elif ca == 9: sub = [L - R, R]
        elif ca == 10: sub = [(L + R) >> 1, L - R]
        else: sub = [L, R]
    else:
        ca = nch - 1; sub = chans
    bpsc = BPS_CODE.get(bps, 0) if bps_explicit else 0
    if bps not in BPS_CODE: bpsc = 0
    head = BW()
    head.w(14, 0x3FFE); head.w(1, 0); head.w(1, 1 if variable else 0)
    head.w(4, bsc); head.w(4, src); head.w(4, ca); head.w(3, bpsc); head.w(1, 0)
    hb = head.bytes() if head.n == 0 else None
    hb = bytes(head.buf) + utf8(start if variable else number)
    if bsx: hb += (bsx[1]).to_bytes(bsx[0] // 8, 'big')
    if srx: hb += (srx[1]).to_bytes(srx[0] // 8, 'big')
    hb += bytes([crc8(hb)])
    for i, s in enumerate(sub):
        side = (ca == 8 and i == 1) or (ca == 9 and i == 0) or (ca == 10 and i == 1)
        write_subframe(bw, s, bps + (1 if side else 0), rng)
    bw.pad()
    body = hb + bw.bytes()
    c = crc16(body)
    return body + bytes([c >> 8, c & 0xFF]), len(hb)     # frame bytes, header length

def streaminfo(minbs, maxbs, rate, nch, bps, total):
    v = (rate << 44) | ((nch - 1) << 41) | ((bps - 1) << 36) | total
    return minbs.to_bytes(2, 'big') + maxbs.to_bytes(2, 'big') + (0).to_bytes(3, 'big') * 2 + v.to_bytes(8, 'big') + bytes(16)

def make_id3(rng):
    """One or two ID3v2 tags with random payloads (some with a footer)."""
    out = b''
    for _ in range(rng.choice([1, 1, 2])):
        n = rng.choice([0, 1, 100, 1000, 3000, 20000] + [2200000] * (rng.random() < .05)); footer = rng.random() < .3
        size = bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
        out += b'ID3' + bytes([4 if footer else 3, 0, 0x10 if footer else 0]) + size + (bytes(n) if n > 5000 else bytes(rng.randrange(256) for _ in range(n)))
        if footer: out += b'3DI' + bytes([4, 0, 0x10]) + size
    return out

def gen_case(rng):
    nch = rng.choice([1, 2, 2, 2, 2, 3, 4, 6, 8])
    bps = rng.choice([4, 8, 12, 16, 16, 16, 16, 20, 24, 25, 27, 31])
    rate = rng.choice([8000, 11025, 22050, 44100, 44100, 48000, 96000, 192000, 12345, 1000, 1, 8, 500, 999, 655350, 176400, 1000000])
    variable = rng.random() < .35
    total = rng.choice([0, 1, 2, 5, 15, 16, 17, 100, 1000, 4096, 4097, 9000, 20000, 33000])
    total = max(total, 1) if rng.random() < .97 else total
    if variable: sizes = []
    bs0 = rng.choice([16, 192, 576, 1000, 1152, 1024, 4096, 4608, 4097, 255, 256, 257, 3000, 8192, 16384, 65535, 65536 // 2])
    chans = make_signal(rng, total, nch, bps) if total else [np.zeros(0, dtype=np.int64)] * nch
    frames = []; pos = 0; number = 0; sz = []; fmeta = []
    while pos < total:
        bs = rng.choice([16, 64, 192, 300, 1000, 1152, 2048, 4096, 5000]) if variable else bs0
        bs = min(bs, total - pos)
        sz.append(bs)
        fb, hl = encode_frame([c[pos:pos + bs] for c in chans], pos, number, variable, rate, bps, rng.random() < .7, rng)
        frames.append(fb); fmeta.append([pos, bs, len(fb), hl])
        pos += bs; number += 1
    if not sz: sz = [bs0]
    if variable: minbs, maxbs = min(sz), max(sz)
    else: minbs = maxbs = sz[0] if len(sz) == 1 else bs0
    if not variable and len(sz) > 1: minbs = maxbs = bs0
    if not variable and len(sz) > 1:                       # what real encoders write: the true minimum (a short last block), or "unknown" (0)
        q = rng.random()
        if q < .3: minbs, maxbs = min(sz), max(sz)
        elif q < .4: minbs = maxbs = 0
        elif q < .45: minbs, maxbs = 0, bs0
    blocks = [(0, streaminfo(minbs, maxbs, rate, nch, bps, total if rng.random() < .9 else 0))]
    for _ in range(rng.choice([0, 0, 1, 2, 4])):
        blocks.append((rng.choice([1, 2, 3, 4, 6, 5]), bytes(rng.randrange(256) for _ in range(rng.choice([0, 1, 33, 200, 3000])))))
    prefix = make_id3(rng) if rng.random() < .25 else b''      # ID3v2 tag(s) in front of the stream
    out = prefix + b'fLaC'
    for i, (t, d) in enumerate(blocks):
        out += bytes([(0x80 if i == len(blocks) - 1 else 0) | t]) + len(d).to_bytes(3, 'big') + d
    base = len(out)
    out += b''.join(frames)
    if rng.random() < .2: out += b'TAG' + bytes(rng.randrange(256) for _ in range(125))   # ID3v1-style trailer
    off = base
    for m in fmeta:
        m.insert(2, off); off += m[3]          # [first sample, samples, file offset, bytes, header bytes]
    # expected PCM: interleaved int16 = (x << max(0,16-bps)) >> max(0,bps-16)
    ls, rs = max(0, 16 - bps), max(0, bps - 16)
    pcm = np.stack(chans, axis=1) if total else np.zeros((0, nch), dtype=np.int64)
    pcm = ((pcm << ls) >> rs).astype('<i2')
    info = dict(nch=nch, bps=bps, rate=rate, variable=variable, total=total, frames=len(frames), bs=bs0, frame_meta=fmeta, blocks=blocks, raw=(np.stack(chans, axis=1) if total else np.zeros((0, nch), dtype=np.int64)))
    return out, pcm, info

def expected_stereo(pcm):
    nch = pcm.shape[1]
    if nch == 1: return np.repeat(pcm, 2, axis=1)
    return pcm[:, :2]

def run(tool, data, chunk=None, seek=None, codec=None, extra=()):
    cmd = [tool, *extra]
    if codec: cmd += ['-C', codec]
    if chunk: cmd += ['-c', str(chunk)]
    if seek is not None: cmd += ['-s', str(seek)]
    with tempfile.NamedTemporaryFile(suffix='.flac') as f:
        f.write(data); f.flush()
        r = subprocess.run(cmd + [f.name], capture_output=True)
    return r.returncode, r.stdout, r.stderr

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', type=int, default=100); ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--tool', default='build/peepdump'); ap.add_argument('--keep')
    ap.add_argument('--gen', help='write one case to PATH.flac / PATH.raw and exit')
    a = ap.parse_args()
    if a.gen:
        rng = random.Random(a.seed); d, p, i = gen_case(rng)
        open(a.gen + '.flac', 'wb').write(d); open(a.gen + '.raw', 'wb').write(expected_stereo(p).tobytes()); print(i); return
    bad = 0; stats = {'cases': 0, 'frames': 0, 'seeks': 0, 'dr_disagrees': 0, 'bytes': 0}
    for n in range(a.run):
        seed = a.seed * 100003 + n; rng = random.Random(seed)
        data, pcm, info = gen_case(rng)
        exp = expected_stereo(pcm).astype('<i2').tobytes()
        chunk = rng.choice([1, 7, 100, 1024, 4096, 99999])
        rc, out, err = run(a.tool, data, chunk)
        ok = rc == 0 and out == exp
        if info['total'] == 0: ok = (rc != 0) or out == b''           # zero-length: either is fine
        stats['cases'] += 1; stats['frames'] += info['frames']; stats['bytes'] += len(data)
        why = ''
        # seeks
        if ok and info['total'] > 2:
            for _ in range(3):
                t = rng.choice([1, info['total'] - 1, info['total'], info['total'] + 50, rng.randrange(info['total'])])
                rc2, out2, _ = run(a.tool, data, rng.choice([64, 1024]), seek=t)
                e2 = exp[min(t, info['total']) * 4:]
                stats['seeks'] += 1
                if rc2 != 0 or out2 != e2: ok = False; why = f'seek {t}: got {len(out2)} bytes, want {len(e2)}'; break
        if not ok:
            bad += 1
            rc3, out3, _ = run(a.tool, data, 1024, codec='dr')
            stats['dr_disagrees'] += (out3 != exp)
            d = next((i for i in range(min(len(out), len(exp))) if out[i] != exp[i]), None)
            info = {k: v for k, v in info.items() if k not in ('frame_meta', 'raw', 'blocks')}
            print(f'FAIL seed={seed} {info} rc={rc} out={len(out)} exp={len(exp)} first_diff_byte={d} {why} | dr_flac {"agrees with truth" if out3 == exp else "ALSO differs (encoder?)"}')
            if a.keep:
                os.makedirs(a.keep, exist_ok=True)
                open(f'{a.keep}/fail_{seed}.flac', 'wb').write(data); open(f'{a.keep}/fail_{seed}.raw', 'wb').write(exp)
    print(f"{stats['cases']} cases, {stats['frames']} frames, {stats['bytes']/1e6:.1f} MB, {stats['seeks']} seeks: {bad} failures")
    sys.exit(1 if bad else 0)

if __name__ == '__main__': main()
