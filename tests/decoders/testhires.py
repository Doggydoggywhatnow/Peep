#!/usr/bin/env python3
"""Checks the full-resolution and high-bit-depth features against an independent model:
  peep_fill32 output (left-justified int32), volume at full precision, the three 16-bit reductions
  (truncate / round / TPDF dither, with a bit-exact model of the dither generator), the damage counter,
  the bit depth, and the FLAC metadata blocks. Streams are the random ones of mkflac.py (4 to 31 bit, 1 to 8
  channels, ID3v2 tags in front, trailers behind).
    testhires.py [--run N] [--seed S] [--tool build/peepdump]
"""
import argparse, random, sys
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import mkflac

ap = argparse.ArgumentParser()
ap.add_argument('--run', type=int, default=150); ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--tool', default='build/peepdump')
# Peep's copy: there is no dr_flac adapter here (Peep removed dr_flac), so the one group of cases that
# needs a 16-bit-only codec can't run. --no-legacy skips it. Everything else is unchanged.
ap.add_argument('--no-legacy', action='store_true')
a = ap.parse_args()

def dither_stream(n, state=0x9E3779B9):
    """The decoder's TPDF dither: xorshift32, two 16-bit halves summed, minus 65535."""
    out = np.empty(n, dtype=np.int64)
    for i in range(n):
        state ^= (state << 13) & 0xFFFFFFFF; state ^= state >> 17; state ^= (state << 5) & 0xFFFFFFFF
        out[i] = (state & 0xFFFF) + (state >> 16) - 65535
    return out

def stereo(raw):
    return np.repeat(raw[:, :1], 2, axis=1) if raw.shape[1] == 1 else raw[:, :2]

def model16(x, bps, gain, mode):
    """Expected int16 stereo for raw stereo samples x (n x 2 int64)."""
    if bps <= 16:                                          # no reduction: the 16-bit path, never dithered
        return ((x << (16 - bps)) * gain) >> 8
    s = ((x << (32 - bps)) * gain) >> 8                    # volume at full precision
    if mode == 0: v = s >> 16
    elif mode == 1: v = (s + 32768) >> 16
    else: v = (s + dither_stream(s.size).reshape(s.shape) + 32768) >> 16
    return np.clip(v, -32768, 32767)

checks = bad = 0
def check(name, ok, info=''):
    global checks, bad
    checks += 1
    if not ok: bad += 1; print(f'FAIL {name} {info}')

for n in range(a.run):
    rng = random.Random(a.seed * 6007 + n)
    data, pcm, info = mkflac.gen_case(rng)
    if info['total'] < 1: continue
    bps = info['bps']; x = stereo(info['raw']).astype(np.int64); tag = f'case {n} (bps {bps}, {info["nch"]} ch)'
    chunk = rng.choice([1, 7, 64, 100, 1024, 99999])
    # 1. full resolution, unity volume
    rc, out, err = mkflac.run(a.tool, data, chunk, extra=['-W', '-E'])
    got = np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None
    check(tag + ' fill32', rc == 0 and got is not None and np.array_equal(got, x << (32 - bps)))
    check(tag + ' bits/errors', b'errors=0 bits=%d' % bps in err)
    # 2. full resolution with volume
    g = rng.choice([0, 1, 100, 164, 255])
    rc, out, _ = mkflac.run(a.tool, data, chunk, extra=['-W', '-g', str(g)])
    got = np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None
    check(tag + f' fill32 gain {g}', rc == 0 and got is not None and np.array_equal(got, ((x << (32 - bps)) * g) >> 8))
    # 3. 16-bit output: every reduction mode, with and without volume
    for mode in (0, 1, 2):
        g = rng.choice([256, 256, 200, 77])
        rc, out, _ = mkflac.run(a.tool, data, chunk, extra=['-D', str(mode), '-g', str(g)])
        got = np.frombuffer(out, dtype='<i2').reshape(-1, 2).astype(np.int64) if len(out) % 4 == 0 else None
        check(tag + f' int16 mode {mode} gain {g}', rc == 0 and got is not None and np.array_equal(got, model16(x, bps, g, mode)))
    # 4. metadata blocks, zero-copy, by type and index
    seen = {}
    for t, d in info['blocks']:
        i = seen.get(t, 0); seen[t] = i + 1
        rc, out, _ = mkflac.run(a.tool, data, extra=['-M', f'{t}:{i}'])
        check(tag + f' metadata {t}:{i}', rc == 0 and out == d)
    rc, out, _ = mkflac.run(a.tool, data, extra=['-M', '5:99'])
    check(tag + ' missing metadata block', rc == 5)
# 5. WAV through peep_fill32 (the built-in path), any channel count
import struct
for n in range(25):
    rng = random.Random(a.seed * 31 + n)
    ch = rng.choice([1, 2, 2, 3, 6, 8]); frames = rng.choice([1, 2, 63, 64, 65, 1000, 4097])
    pcm = np.array([[rng.randint(-32768, 32767) for _ in range(ch)] for _ in range(frames)], dtype='<i2')
    body = pcm.tobytes()
    wav = (b'RIFF' + struct.pack('<I', 36 + len(body)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, ch, 44100, 44100 * ch * 2, ch * 2, 16)
           + b'data' + struct.pack('<I', len(body)) + body)
    x = stereo(pcm.astype(np.int64)); g = rng.choice([256, 256, 100, 0, 255]); chunk = rng.choice([1, 7, 100, 99999])
    rc, out, _ = mkflac.run(a.tool, wav, chunk, extra=['-W', '-g', str(g)])
    got = np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None
    check(f'wav {ch} ch fill32 gain {g}', rc == 0 and got is not None and np.array_equal(got, ((x << 16) * g) >> 8))

# 6. a codec with no full-resolution mode (the dr_flac adapter): peep_fill32 widens its 16-bit output
for n in range(0 if a.no_legacy else 25):
    rng = random.Random(a.seed * 53 + n)
    data, pcm, info = mkflac.gen_case(rng)
    if info['total'] < 1 or info['bps'] > 24: continue
    bps = info['bps']; x = stereo(info['raw']).astype(np.int64)
    rc, ref, _ = mkflac.run(a.tool, data, 1024, codec='dr')
    if rc != 0: continue                                    # dr_flac declined this stream
    g = rng.choice([256, 100]); rc, out, _ = mkflac.run(a.tool, data, rng.choice([1, 100, 99999]), codec='dr', extra=['-W', '-g', str(g)])
    v16 = np.frombuffer(ref, dtype='<i2').reshape(-1, 2).astype(np.int64)    # what the adapter returns at unity volume
    got = np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None
    check(f'legacy codec fill32 (bps {bps}) gain {g}', rc == 0 and got is not None and np.array_equal(got, (v16 * g) << 8))
print(f'{checks} checks, {bad} failures')
sys.exit(1 if bad else 0)
