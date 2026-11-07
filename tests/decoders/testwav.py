#!/usr/bin/env python3
"""Self-contained test of the built-in WAV decoder: header variants, channel counts,
every chunk size, volume, seeking, and files that must be rejected."""
import struct, subprocess, sys, tempfile, random
import numpy as np
tool = sys.argv[1] if len(sys.argv) > 1 else 'build/peepdump'
rng = np.random.RandomState(3); fails = 0; checks = 0

def fmt(ch=2, rate=44100, bits=16, tag=1, size=16):
    ba = ch * bits // 8; b = struct.pack('<HHIIHH', tag, ch, rate, rate * ba, ba, bits)
    if size == 18: b += struct.pack('<H', 0)
    if size == 40: b += struct.pack('<HHI', 22, bits, 3) + bytes.fromhex('0100000000001000800000aa00389b71')
    return b'fmt ' + struct.pack('<I', len(b)) + b
def chunk(i, b): return i + struct.pack('<I', len(b)) + b + (b'\0' if len(b) & 1 else b'')
def riff(*p): body = b'WAVE' + b''.join(p); return b'RIFF' + struct.pack('<I', len(body)) + body

def run(data, *args):
    with tempfile.NamedTemporaryFile(suffix='.wav') as f:
        f.write(data); f.flush()
        r = subprocess.run([tool, *args, f.name], capture_output=True)
    return r.returncode, r.stdout

def expect(pcm, ch, gain=256):
    pcm = pcm.reshape(-1, ch).astype(np.int64)
    st = np.repeat(pcm[:, :1], 2, axis=1) if ch == 1 else pcm[:, :2]
    return ((st * gain) >> 8).astype('<i2').tobytes()

def check(name, ok):
    global fails, checks; checks += 1
    if not ok: fails += 1; print('FAIL', name)

for ch in (1, 2, 3, 6, 8):
    for n in (0, 1, 3, 4, 5, 1000, 4099):
        pcm = rng.randint(-32768, 32768, n * ch).astype('<i2')
        for name, data in (('plain', riff(fmt(ch), chunk(b'data', pcm.tobytes()))),
                           ('fmt18', riff(fmt(ch, size=18), chunk(b'data', pcm.tobytes()))),
                           ('ext', riff(fmt(ch, tag=0xFFFE, size=40), chunk(b'data', pcm.tobytes()))),
                           ('oddchunk', riff(fmt(ch), chunk(b'junk', b'abc'), chunk(b'LIST', b'12345'), chunk(b'data', pcm.tobytes()))),
                           ('streaming', riff(fmt(ch), b'data' + struct.pack('<I', 0xFFFFFFFF) + pcm.tobytes()))):
            for gain in (256, 164, 0, 1, 255):
                for chunk_sz in (1, 7, 1024):
                    if gain != 256 and chunk_sz == 7 and n > 5: continue
                    rc, out = run(data, '-g', str(gain), '-c', str(chunk_sz))
                    if n == 0: check(f'{name} ch{ch} n0', rc == 0 and out == b'' or rc != 0); continue
                    check(f'{name} ch{ch} n{n} g{gain} c{chunk_sz}', rc == 0 and out == expect(pcm, ch, gain))
        if n > 5:
            pcm = rng.randint(-32768, 32768, n * ch).astype('<i2'); data = riff(fmt(ch), chunk(b'data', pcm.tobytes()))
            for t in (0, 1, n // 2, n - 1, n, n + 100):
                rc, out = run(data, '-s', str(t)); check(f'seek ch{ch} n{n} t{t}', out == expect(pcm, ch)[min(t, n) * 4:])
            rc, out = run(data[:len(data) - 5 * ch * 2 - 1], '-c', '999')        # truncated file plays what is there
            check(f'truncated ch{ch} n{n}', rc == 0 and out == expect(pcm, ch)[:(n - 6) * 4])

good = rng.randint(-1000, 1000, 100).astype('<i2').tobytes()
for name, data in (('data before fmt', riff(chunk(b'data', good), fmt())), ('zero channels', riff(fmt(0), chunk(b'data', good))),
                   ('rate 0', riff(fmt(rate=0), chunk(b'data', good))), ('9 channels', riff(fmt(9), chunk(b'data', good))),
                   ('adpcm', riff(fmt(tag=2, bits=4), chunk(b'data', good))),
                   ('huge chunk', riff(fmt(), b'LIST' + struct.pack('<I', 0xFFFFFFF0) + b'xx')), ('tiny', b'RIFF\x04\0\0\0WAVE'),
                   ('garbage', b'hello this is not audio' * 50), ('empty fmt', riff(b'fmt ' + struct.pack('<I', 0), chunk(b'data', good)))):
    rc, out = run(data); check('reject ' + name, rc != 0 and out == b'')
print(f'{checks} WAV checks, {fails} failures'); sys.exit(1 if fails else 0)
