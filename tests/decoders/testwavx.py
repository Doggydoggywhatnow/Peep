#!/usr/bin/env python3
"""Checks the WAV extension codec (wav.asm / arm64/wav.s) against an independent model: unsigned 8-bit,
12/16/20/24/32-bit PCM, 32 and 64-bit float, plain and WAVE_FORMAT_EXTENSIBLE, 1 to 8 channels, seeking,
truncated and unknown-length files, volume, the three 16-bit modes, peep_fill32, and files that must be rejected.
    testwavx.py [--run N] [--seed S] [--tool build/peepdump]      testwavx.py --gen DIR   (fuzz seeds)
"""
import argparse, random, struct, sys, os
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import mkflac

ap = argparse.ArgumentParser()
ap.add_argument('--run', type=int, default=150); ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--tool', default='build/peepdump'); ap.add_argument('--gen')
a = ap.parse_args()
GUID = bytes.fromhex('000000001000800000aa00389b71')

def fmt_chunk(tag, ch, cbits, vbits, ext, rate=44100, bytes_per_sample=None):
    cb = cbits // 8; ba = ch * cb
    if ext:
        b = struct.pack('<HHIIHHHHI', 0xFFFE, ch, rate, rate * ba, ba, cbits, 22, vbits, 3) + struct.pack('<H', tag) + GUID
    else:
        b = struct.pack('<HHIIHH', tag, ch, rate, rate * ba, ba, vbits)
    return b'fmt ' + struct.pack('<I', len(b)) + b

def riff(*parts):
    body = b'WAVE' + b''.join(parts); return b'RIFF' + struct.pack('<I', len(body)) + body

def data_chunk(b, unknown=False):
    return b'data' + struct.pack('<I', 0xFFFFFFFF if unknown else len(b)) + b + (b'\0' if len(b) & 1 and not unknown else b'')

def to_i32(x64):
    x = np.where(np.isnan(x64), 0.0, x64 * 2147483648.0)
    return np.clip(np.rint(x), -2147483648, 2147483647).astype(np.int64)

FLOATS = [0.0, -0.0, 1.0, -1.0, 0.5, 0.99999994, -0.99999994, 1.5, -2.0, 1e-30, 1e30, float('inf'), float('-inf'), float('nan'), 3e-45]

def make(kind, ch, n, rng):
    """-> (raw bytes of the data chunk, left-justified int32 samples (n x ch), container bits, valid bits)"""
    cnt = n * ch
    if kind == 'u8':
        v = np.array([rng.randrange(256) for _ in range(cnt)], dtype=np.uint8); return v.tobytes(), (v.astype(np.int64) - 128) << 24, 8, 8
    if kind in ('s16', 's12'):
        vb = 16 if kind == 's16' else 12
        v = np.array([rng.randint(-32768, 32767) for _ in range(cnt)], dtype='<i2')
        if vb == 12: v = (v & ~0xF).astype('<i2')
        return v.tobytes(), v.astype(np.int64) << 16, 16, vb
    if kind in ('s24', 's20'):
        vb = 24 if kind == 's24' else 20
        v = np.array([rng.randint(-(1 << 23), (1 << 23) - 1) for _ in range(cnt)], dtype=np.int64)
        if vb == 20: v &= ~0xF
        b = b''.join(int(x & 0xFFFFFF).to_bytes(3, 'little') for x in v); return b, v << 8, 24, vb
    if kind == 's32':
        v = np.array([rng.choice([rng.randint(-2**31, 2**31 - 1), -2**31, 2**31 - 1, 0]) for _ in range(cnt)], dtype='<i4'); return v.tobytes(), v.astype(np.int64), 32, 32
    vals = []
    for _ in range(cnt):
        r = rng.random()
        if r < .15: vals.append(rng.choice(FLOATS))
        elif r < .3 and kind == 'f64': vals.append((rng.randint(-2**31, 2**31 - 1) + .5) / 2**31)     # exact rounding ties
        elif r < .4 and kind == 'f64': vals.append(rng.choice([(2**31 - 1 + .5) / 2**31, (2**31 - 1 + .25) / 2**31, (2**31 - 1 + .75) / 2**31, (-2**31 - .5) / 2**31, (-2**31 - .75) / 2**31, (2**31 - 1) / 2**31]))   # at the saturation edge
        else: vals.append(rng.uniform(-1.2, 1.2))
    if kind == 'f32':
        v = np.array(vals, dtype='<f4'); return v.tobytes(), to_i32(v.astype(np.float64)), 32, 32
    v = np.array(vals, dtype='<f8'); return v.tobytes(), to_i32(v), 64, 32

def stereo(x, ch):
    x = x.reshape(-1, ch); return np.repeat(x[:, :1], 2, axis=1) if ch == 1 else x[:, :2]

def dither_stream(n, state=0x9E3779B9):
    out = np.empty(n, dtype=np.int64)
    for i in range(n):
        state ^= (state << 13) & 0xFFFFFFFF; state ^= state >> 17; state ^= (state << 5) & 0xFFFFFFFF
        out[i] = (state & 0xFFFF) + (state >> 16) - 65535
    return out

def model16(L, bits, gain, mode):
    if bits <= 16: return (((L >> 16) * gain) >> 8)
    s = (L * gain) >> 8
    if mode == 0: v = s >> 16
    elif mode == 1: v = (s + 32768) >> 16
    else: v = (s + dither_stream(s.size).reshape(s.shape) + 32768) >> 16
    return np.clip(v, -32768, 32767)

def build(kind, ch, n, rng, ext=None, unknown=False):
    raw, L, cbits, vbits = make(kind, ch, n, rng)
    tag = 3 if kind[0] == 'f' else 1
    ext = rng.random() < .4 if ext is None else ext
    f = fmt_chunk(tag, ch, cbits, vbits if not kind[0] == 'f' else cbits, ext)
    extra = [b''] if rng.random() < .6 else [chunk_junk(rng)]
    return riff(f, *extra, data_chunk(raw, unknown)), raw, L.reshape(-1, ch), vbits if kind[0] != 'f' else 32, cbits

def chunk_junk(rng):
    n = rng.choice([1, 3, 4, 7]); return b'LIST' + struct.pack('<I', n) + bytes(n) + (b'\0' if n & 1 else b'')

KINDS = ['u8', 's16', 's12', 's24', 's20', 's32', 'f32', 'f64']

if a.gen:
    os.makedirs(a.gen, exist_ok=True)
    for i, k in enumerate(['u8', 's24', 'f32', 'f64', 's12']):
        w = build(k, 2, 300, random.Random(i), ext=(k == 'f64'))[0]; open(f'{a.gen}/w{i}.wav', 'wb').write(w)
    sys.exit(0)

checks = bad = 0
def check(name, ok, info=''):
    global checks, bad
    checks += 1
    if not ok: bad += 1; print(f'FAIL {name} {info}')

def i16(out): return np.frombuffer(out, dtype='<i2').reshape(-1, 2).astype(np.int64) if len(out) % 4 == 0 else None
def i32(out): return np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None

for n in range(a.run):
    rng = random.Random(a.seed * 7919 + n)
    kind = KINDS[n % len(KINDS)]; ch = rng.choice([1, 2, 2, 2, 3, 6, 8]); frames = rng.choice([1, 2, 5, 63, 64, 65, 1000, 4099])
    unknown = rng.random() < .15
    wav, raw, L, bits, cbits = build(kind, ch, frames, rng, unknown=unknown)
    x = stereo(L, ch); tag = f'{kind} ch{ch} n{frames}' + (' ext' if b'\xfe\xff' in wav[20:24] else '')
    chunk = rng.choice([1, 7, 64, 100, 1024, 99999])
    if kind == 's12' and ' ext' in tag: bits = 16        # a 16-bit extensible file is the core's: it reports the container
    g = rng.choice([256, 256, 100, 0, 255])
    rc, out, err = mkflac.run(a.tool, wav, chunk, extra=['-E'])
    check(tag + ' default', rc == 0 and np.array_equal(i16(out), model16(x, bits, 256, 0)) and b'bits=%d' % bits in err)
    for mode in (0, 1, 2):
        rc, out, _ = mkflac.run(a.tool, wav, chunk, extra=['-D', str(mode), '-g', str(g)])
        check(tag + f' int16 mode {mode} gain {g}', rc == 0 and np.array_equal(i16(out), model16(x, bits, g, mode)))
    rc, out, _ = mkflac.run(a.tool, wav, chunk, extra=['-W', '-g', str(g)])
    check(tag + f' fill32 gain {g}', rc == 0 and np.array_equal(i32(out), (x * g) >> 8))
    t = rng.choice([0, 1, frames // 2, frames - 1, frames, frames + 50]); t0 = min(t, frames)
    rc, out, _ = mkflac.run(a.tool, wav, chunk, extra=['-W', '-s', str(t)])
    check(tag + f' seek {t}', (rc == 0 and np.array_equal(i32(out), x[t0:])) if t0 < frames else out == b'')
    if frames > 5 and not unknown:                       # a truncated file plays what is there
        fsz = ch * cbits // 8; cut = rng.randint(1, 3 * fsz)
        have = (len(raw) + (len(raw) & 1) - cut) // fsz
        rc, out, _ = mkflac.run(a.tool, wav[:len(wav) - cut], chunk, extra=['-W'])
        check(tag + f' truncated by {cut}', rc == 0 and np.array_equal(i32(out), x[:have]), f'have {have}')

# files that must be rejected
rng = random.Random(5); good = bytes(range(200)) * 2
def bad_fmt(tag, ch, ba, bits, rate=44100): return b'fmt ' + struct.pack('<IHHIIHH', 16, tag, ch, rate, rate * ba, ba, bits)
rejects = {
 '5-byte samples': riff(bad_fmt(1, 2, 10, 40), data_chunk(good)), '9 channels': riff(bad_fmt(1, 9, 18, 16), data_chunk(good)),
 'zero channels': riff(bad_fmt(1, 0, 0, 24), data_chunk(good)), 'float 16-bit': riff(bad_fmt(3, 2, 4, 16), data_chunk(good)),
 'float 24-bit': riff(bad_fmt(3, 2, 6, 24), data_chunk(good)), 'valid bits above container': riff(bad_fmt(1, 2, 6, 32), data_chunk(good)),
 'block align mismatch': riff(bad_fmt(1, 2, 5, 24), data_chunk(good)), 'block align not a multiple': riff(bad_fmt(1, 2, 5, 8), data_chunk(good)), 'ADPCM': riff(bad_fmt(2, 2, 4, 4), data_chunk(good)),
 'data before fmt': riff(data_chunk(good), bad_fmt(1, 2, 6, 24)), 'rate 0': riff(bad_fmt(1, 2, 6, 24, 0), data_chunk(good)),
 'no data': riff(bad_fmt(1, 2, 6, 24)), 'tiny': b'RIFF\x04\0\0\0WAVE',
}
for name, d in rejects.items():
    rc, out, _ = mkflac.run(a.tool, d, 100, extra=['-W']); check('reject ' + name, rc != 0 and out == b'')
print(f'{checks} checks, {bad} failures'); sys.exit(1 if bad else 0)
