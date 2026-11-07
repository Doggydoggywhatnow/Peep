#!/usr/bin/env python3
"""Checks the FLAC frame CRC-16: flip one bit inside the audio of one frame (or in its CRC) and
the decoder must never output wrong samples. Allowed results, and nothing else:
  silenced: that frame's samples are zero, every other frame is exact (the CRC-16 caught it)
  dropped : that frame is missing, every other frame is exact (the damage broke the frame's structure)
    testcrc.py [--run N] [--seed S] [--tool build/peepdump]
"""
import argparse, random, sys
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import mkflac

ap = argparse.ArgumentParser()
ap.add_argument('--run', type=int, default=300); ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--tool', default='build/peepdump')
a = ap.parse_args()
n_cases = silenced = dropped = bad = 0
for n in range(a.run):
    rng = random.Random(a.seed * 7919 + n)
    data, pcm, info = mkflac.gen_case(rng)
    if info['total'] < 1 or not info['frame_meta']: continue
    exp = mkflac.expected_stereo(pcm).astype('<i2')
    f = rng.randrange(len(info['frame_meta']))
    start, cnt, off, length, hdr = info['frame_meta'][f]
    pos = off + rng.randrange(hdr, length)                  # audio payload or the CRC itself
    bit = rng.randrange(8)
    bad_data = bytearray(data); bad_data[pos] ^= 1 << bit
    rc, out, err = mkflac.run(a.tool, bytes(bad_data), rng.choice([1, 100, 1024, 99999]), extra=['-E'])
    errs = int(err.split(b'errors=')[1].split()[0]) if b'errors=' in err else -1
    n_cases += 1
    silent = exp.copy(); silent[start:start + cnt] = 0
    drop = np.delete(exp, np.s_[start:start + cnt], axis=0)
    if rc == 0 and out == silent.tobytes() and errs >= 1: silenced += 1
    elif rc == 0 and out == drop.tobytes() and errs >= 1: dropped += 1
    else:
        bad += 1
        got = np.frombuffer(out, dtype='<i2').reshape(-1, 2) if len(out) % 4 == 0 else None
        print(f'FAIL case {n}: frame {f} of {len(info["frame_meta"])} byte {pos - off} bit {bit}: '
              f'errors={errs} rc={rc} frames_out={len(out)//4} expected {len(exp)} (or {len(drop)})')
print(f'{n_cases} corrupted streams: {silenced} silenced by the CRC-16, {dropped} dropped by resync (both counted in p->errors), {bad} wrong')
sys.exit(1 if bad else 0)
