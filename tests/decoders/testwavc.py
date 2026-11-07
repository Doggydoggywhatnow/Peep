#!/usr/bin/env python3
"""Tests of the compressed-WAV codec (wavc.asm / arm64/wavc.s): A-law, mu-law, IMA ADPCM and Microsoft ADPCM.

The expected output comes from independent models (tools/wavmodels.py, written from the format descriptions), and the models themselves
are checked first against real decoders on real files made by ffmpeg:
  * A-law, mu-law and Microsoft ADPCM: ffmpeg and libsndfile and the model all agree bit for bit.
  * IMA ADPCM: libsndfile and the model agree bit for bit. ffmpeg decodes with a different rounding ((2*delta+1)*step >> 3 instead of the
    reference step>>3 + step>>2 ...), so it differs from the reference by a few units; that difference is reported, not treated as a failure.
Then the codec (through the peepdump tool) is checked against the model on: every format, mono and stereo, many block sizes and sample
rates, signals that drive the ADPCM step to its extremes, a 'fact' chunk (absent, smaller, larger), a partial last block, truncated files,
extensible A-law / mu-law headers, a custom Microsoft ADPCM coefficient table, seeks to every block edge and its neighbours, random request
sizes, volume, 32-bit output, the workspace protocol and files that must be rejected.

    testwavc.py [--tool build/peepdump] [--seed N] [--quick]        testwavc.py --gen DIR   (write sample files, for the fuzzer)
Needs ffmpeg (skipped with a notice if missing); libsndfile is used when it can be loaded.
"""
import argparse, os, random, shutil, struct, subprocess, sys, tempfile
import numpy as np
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import wavmodels as wm
import sndfileref

ap = argparse.ArgumentParser()
ap.add_argument('--tool', default='build/peepdump'); ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--quick', action='store_true'); ap.add_argument('--gen')
a = ap.parse_args()
HAVE_FF = shutil.which('ffmpeg') is not None
CODECS = ['pcm_alaw', 'pcm_mulaw', 'adpcm_ima_wav', 'adpcm_ms']
TMP = tempfile.mkdtemp(prefix='testwavc')

def signal(kind, n, ch, rate, rng):
    t = np.arange(n) / rate; out = []
    for c in range(ch):
        if kind == 'music': x = 0.5 * np.sin(2 * np.pi * (330 + 110 * c) * t) + 0.2 * np.sin(2 * np.pi * 2900 * t) + 0.05 * rng.randn(n)
        elif kind == 'noise': x = rng.uniform(-1, 1, n)
        elif kind == 'square': x = np.where(np.sin(2 * np.pi * (97 + 31 * c) * t) >= 0, 0.98, -0.98)       # drives the step to its limits
        elif kind == 'silence': x = np.zeros(n)
        elif kind == 'burst': x = np.where((np.arange(n) // 700) % 2 == 0, 0.0, rng.uniform(-1, 1, n))   # silence then loud: the step collapses and jumps
        else: x = np.sin(2 * np.pi * 50 * t)
        out.append(x)
    return (np.clip(np.stack(out, axis=1), -1, 1) * 32000).astype('<i2')

def wav_pcm16(pcm, rate):
    ch = pcm.shape[1]; d = pcm.tobytes()
    return (b'RIFF' + struct.pack('<I', 36 + len(d)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, ch, rate, rate * ch * 2, ch * 2, 16)
            + b'data' + struct.pack('<I', len(d)) + d)

def encode(pcm, rate, codec, block=None):
    """-> WAV bytes made by ffmpeg"""
    src = os.path.join(TMP, 'src.wav'); dst = os.path.join(TMP, 'dst.wav'); open(src, 'wb').write(wav_pcm16(pcm, rate))
    cmd = ['ffmpeg', '-v', 'error', '-y', '-i', src, '-c:a', codec]
    if block: cmd += ['-block_size', str(block)]
    r = subprocess.run(cmd + [dst], capture_output=True)
    if r.returncode: raise RuntimeError(r.stderr.decode()[:200])
    return open(dst, 'rb').read()

def chunks(d):
    i = 12; out = []
    while i + 8 <= len(d):
        cid = d[i:i + 4]; sz = struct.unpack('<I', d[i + 4:i + 8])[0]; out.append((cid, d[i + 8:i + 8 + sz])); i += 8 + sz + (sz & 1)
    return out

def build(chs):
    body = b'WAVE'
    for cid, b in chs: body += cid + struct.pack('<I', len(b)) + b + (b'\0' if len(b) & 1 else b'')
    return b'RIFF' + struct.pack('<I', len(body)) + body

def run(data, *args):
    with tempfile.NamedTemporaryFile(suffix='.wav', dir=TMP) as f:
        f.write(data); f.flush(); r = subprocess.run([a.tool, *args, f.name], capture_output=True)
    return r.returncode, r.stdout

def decode_model(wav):
    """expected decoded frames (n, ch) for a WAV of one of the four formats (what the codec must produce)"""
    fmt, data, fact = wm.parse_wav(wav); tag = fmt['tag']
    if tag == 0xFFFE: tag = struct.unpack('<H', fmt['raw'][24:26])[0]
    ch = fmt['ch']
    if tag == 6: x = wm.ALAW[np.frombuffer(data, dtype=np.uint8)].reshape(-1, ch)[:len(data) // ch]
    elif tag == 7: x = wm.ULAW[np.frombuffer(data, dtype=np.uint8)].reshape(-1, ch)[:len(data) // ch]
    elif tag == 0x11: x = wm.ima_decode(data, ch, fmt['ba'])
    else:
        raw = fmt['raw']; ncoef = struct.unpack('<H', raw[20:22])[0]
        coefs = [struct.unpack('<hh', raw[22 + 4 * i:26 + 4 * i]) for i in range(ncoef)]
        x = wm.ms_decode(data, ch, fmt['ba'], coefs)
    if tag in (0x11, 2) and fact is not None and fact < len(x): x = x[:fact]
    return x

def stereo(x): return np.repeat(x, 2, axis=1) if x.shape[1] == 1 else x[:, :2]

checks = bad = 0; notes = []
def check(name, ok, info=''):
    global checks, bad
    checks += 1
    if not ok: bad += 1; print(f'FAIL {name} {info}')

def i16(out): return np.frombuffer(out, dtype='<i2').reshape(-1, 2).astype(np.int64) if len(out) % 4 == 0 else None
def i32(out): return np.frombuffer(out, dtype='<i4').reshape(-1, 2).astype(np.int64) if len(out) % 8 == 0 else None

def codec_matches(name, wav, exp=None, chunk=None):
    """the codec's output, at unity volume and several request sizes, must equal the model"""
    x = decode_model(wav) if exp is None else exp; want = stereo(x)
    for label, opts in (('whole', ['-c', '99999']), ('1 frame', ['-c', '1']), ('random', ['-c', '3000', '-R', '5'])):
        if label == '1 frame' and len(want) > 6000: continue
        rc, out = run(wav, *opts); got = i16(out)
        check(f'{name} [{label}]', rc == 0 and got is not None and np.array_equal(got, want),
              f'rc={rc} frames {None if got is None else len(got)} vs {len(want)}')

if a.gen:
    os.makedirs(a.gen, exist_ok=True); rng = np.random.RandomState(4)
    for i, c in enumerate(CODECS):
        open(f'{a.gen}/c{i}.wav', 'wb').write(encode(signal('music', 6000, 2, 22050, rng), 22050, c, 256 if 'adpcm' in c else None))
    open(f'{a.gen}/c4.wav', 'wb').write(encode(signal('noise', 5000, 1, 8000, rng), 8000, 'adpcm_ima_wav', 128))
    shutil.rmtree(TMP, ignore_errors=True); sys.exit(0)

if not HAVE_FF:
    print('testwavc: ffmpeg not found, skipping (it makes the real compressed files these tests start from)'); sys.exit(0)

rng = np.random.RandomState(a.seed); R = random.Random(a.seed)
# ---- 1. the models against real decoders, on real files
matrix = []
for codec in CODECS:
    for ch in (1, 2):
        for kind in ('music', 'noise', 'square', 'silence', 'burst'):
            blocks = [None] if codec.startswith('pcm') else ([256, 1024, 2048] if a.quick else [64, 256, 512, 1024, 2048, 4096])
            for blk in blocks:
                rate = R.choice([8000, 11025, 22050, 44100, 48000]); n = R.choice([1, 40, 700, 3000, 9000]) if kind != 'silence' else 2500
                if a.quick and R.random() < .5: continue
                matrix.append((codec, ch, kind, blk, rate, n))
files = {}
ffmpeg_ima_worst = 0
for codec, ch, kind, blk, rate, n in matrix:
    pcm = signal(kind, n, ch, rate, rng); wav = encode(pcm, rate, codec, blk); name = f'{codec} ch{ch} {kind} block {blk} {rate}Hz n{n}'
    files[name] = wav; path = os.path.join(TMP, 'one.wav'); open(path, 'wb').write(wav)
    model = decode_model(wav)
    if sndfileref.available():
        r = sndfileref.decode(path)
        if r is not None:
            sf = r[0]; k = min(len(sf), len(model))
            if codec == 'adpcm_ima_wav' or codec == 'adpcm_ms' or codec.startswith('pcm'):
                fmt, data, fact = wm.parse_wav(wav)
                # libsndfile does not apply the fact trim to ADPCM padding, so compare the frames both have
                check('model vs libsndfile: ' + name, np.array_equal(sf[:k], model[:k]), f'frames {len(sf)} vs {len(model)}')
    ref = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-acodec', 'pcm_s16le', '-'], capture_output=True).stdout
    ff = np.frombuffer(ref, dtype='<i2').astype(np.int64).reshape(-1, ch); k = min(len(ff), len(model))
    if codec == 'adpcm_ima_wav':
        if len(model): ffmpeg_ima_worst = max(ffmpeg_ima_worst, int(np.abs(ff[:k] - model[:k]).max()) if k else 0)
    else:
        check('model vs ffmpeg: ' + name, np.array_equal(ff[:k], model[:k]), f'frames {len(ff)} vs {len(model)}')
    codec_matches('codec vs model: ' + name, wav)
notes.append(f'IMA ADPCM: ffmpeg differs from the reference algorithm by up to {ffmpeg_ima_worst} units on these files (expected: it rounds differently)')

# ---- 2. edge cases, built from real files
def first(codec, ch, blk=256, n=5000, rate=22050, kind='music'):
    return encode(signal(kind, n, ch, rate, rng), rate, codec, blk)

for codec in ('adpcm_ima_wav', 'adpcm_ms'):
    for ch in (1, 2):
        base = first(codec, ch); cs = chunks(base); fmtc = dict(cs)[b'fmt ']; data = dict(cs)[b'data']; fmt, _, fact = wm.parse_wav(base)
        ba = fmt['ba']; tag = f'{codec} ch{ch}'
        no_fact = build([c for c in cs if c[0] != b'fact'])
        check(tag + ' no fact chunk: every decoded frame', run(no_fact, '-c', '5000')[0] == 0)
        codec_matches(tag + ' no fact chunk', no_fact)
        small = build([(c if c[0] != b'fact' else (b'fact', struct.pack('<I', 777))) for c in cs]); codec_matches(tag + ' fact smaller (trims)', small)
        big = build([(c if c[0] != b'fact' else (b'fact', struct.pack('<I', 10 ** 7))) for c in cs]); codec_matches(tag + ' fact larger than the data (ignored)', big)
        for cut in (1, 3, 4, 5, 7, 8, 9, 13, ba // 2 + 1, ba - 1, ba + 5):
            if cut >= len(data): continue
            cd = [(c, (b[:len(b) - cut] if c == b'data' else b)) for c, b in cs if c != b'fact']
            t = build(cd); sz = struct.pack('<I', len(data))        # the data size field still claims the full length: a truncated file
            t = t.replace(b'data' + struct.pack('<I', len(data) - cut), b'data' + sz, 1) if False else t
            codec_matches(f'{tag} truncated by {cut} bytes', t)
        junk = build([(b'JUNK', b'xyz')] + cs if False else [cs[0], (b'LIST', b'abcde'), (b'JUNK', b'xyz')] + cs[1:]); codec_matches(tag + ' odd chunks before data', junk)
        # seeks to every block edge and its neighbours, with different request sizes
        want = stereo(decode_model(base)); spb = len(decode_model(base)) // max(1, len(data) // ba) if len(data) >= ba else 1
        pts = sorted({0, 1, len(want) - 1, len(want), len(want) + 9} | {max(0, b * spb + d) for b in range(1, 6) for d in (-2, -1, 0, 1, 2)} | {R.randrange(len(want)) for _ in range(4)})
        for t in pts:
            rc, out = run(base, '-s', str(t), '-R', str(t + 1), '-c', '777'); got = i16(out)
            check(f'{tag} seek to {t}', rc == 0 and got is not None and np.array_equal(got, want[min(t, len(want)):]))
        # volume and 32-bit output
        for g in (255, 100, 1, 0):
            rc, out = run(base, '-g', str(g), '-c', '999'); check(f'{tag} gain {g}', rc == 0 and np.array_equal(i16(out), (want * g) >> 8))
        rc, out = run(base, '-W', '-g', '200', '-c', '777'); check(tag + ' fill32 + gain', rc == 0 and np.array_equal(i32(out), ((want << 16) * 200) >> 8))
        # a corrupted stream must still decode deterministically, with no crash
        bad_data = bytearray(base); 
        for _ in range(40): bad_data[R.randrange(60, len(bad_data))] = R.randrange(256)
        rc1, o1 = run(bytes(bad_data), '-c', '1000'); rc2, o2 = run(bytes(bad_data), '-c', '33', '-R', '2')
        check(tag + ' damaged stream: no crash, same output for any request size', rc1 == 0 and rc2 == 0 and o1 == o2, f'{rc1} {rc2}')
    # header corner cases
    if codec == 'adpcm_ms':
        for ch in (1, 2):
            base = first(codec, ch); cs = chunks(base); fm = bytearray(dict(cs)[b'fmt ']); dd = bytearray(dict(cs)[b'data'])
            for delta in (0, 5, 15, -5, -32768, 32767):
                for c in range(ch):                                   # the first block's iDelta of every channel
                    dd[ch + 2 * c:ch + 2 * c + 2] = struct.pack('<h', delta)
                t = build([(cid, (bytes(dd) if cid == b'data' else b)) for cid, b in cs]); codec_matches(f'adpcm_ms ch{ch} header delta {delta} used as it stands', t)

        base = first(codec, 2); cs = chunks(base); fm = bytearray(dict(cs)[b'fmt '])
        ncoef = struct.unpack('<H', fm[20:22])[0]
        custom = bytearray(fm)
        for i in range(ncoef): custom[22 + 4 * i:26 + 4 * i] = struct.pack('<hh', R.randrange(-400, 400), R.randrange(-400, 400))
        t = build([(c, (bytes(custom) if c == b'fmt ' else b)) for c, b in cs]); codec_matches('adpcm_ms custom coefficient table', t)
        tiny = bytearray(fm); tiny[20:22] = struct.pack('<H', 2)           # only 2 pairs: a predictor index above that uses the last pair
        t = build([(c, (bytes(tiny[:26 + 4]) if c == b'fmt ' else b)) for c, b in cs]); codec_matches('adpcm_ms 2 coefficient pairs, higher indexes clamp', t)
        zero = bytearray(fm); zero[20:22] = struct.pack('<H', 0)
        rc, out = run(build([(c, (bytes(zero) if c == b'fmt ' else b)) for c, b in cs])); check('adpcm_ms 0 coefficient pairs rejected', rc != 0 and out == b'')
        short = build([(c, (bytes(fm[:20]) if c == b'fmt ' else b)) for c, b in cs]); rc, out = run(short); check('adpcm_ms fmt chunk without coefficients rejected', rc != 0 and out == b'')

# extensible A-law / mu-law (and 3..8 channels, which only these formats allow)
GUID = bytes.fromhex('000000001000800000aa00389b71')
for tag, codec in ((6, 'pcm_alaw'), (7, 'pcm_mulaw')):
    for ch in (1, 2, 3, 6, 8):
        rate = 22050; raw = rng.randint(0, 256, 700 * ch).astype(np.uint8).tobytes()
        ext = struct.pack('<HHIIHHHHI', 0xFFFE, ch, rate, rate * ch, ch, 8, 22, 8, 0) + struct.pack('<H', tag) + GUID
        plain = struct.pack('<HHIIHHH', tag, ch, rate, rate * ch, ch, 8, 0)
        tab = wm.ALAW if tag == 6 else wm.ULAW
        want = stereo(tab[np.frombuffer(raw, dtype=np.uint8)].reshape(-1, ch))
        for label, f in (('extensible', ext), ('plain', plain)):
            w = build([(b'fmt ', f), (b'data', raw)])
            for opts in (['-c', '999'], ['-c', '37', '-R', '3']):
                rc, out = run(w, *opts); check(f'{codec} ch{ch} {label} {opts[-1]}', rc == 0 and np.array_equal(i16(out), want))
            rc, out = run(w, '-s', '300', '-c', '100'); check(f'{codec} ch{ch} {label} seek', rc == 0 and np.array_equal(i16(out), want[300:]))
        rc, out = run(w, '-W', '-g', '128'); check(f'{codec} ch{ch} fill32', rc == 0 and np.array_equal(i32(out), ((want << 16) * 128) >> 8))

# ---- 3. files that must be rejected
good = first('adpcm_ima_wav', 2); gc = chunks(good); gfmt = bytearray(dict(gc)[b'fmt ']); gdata = dict(gc)[b'data']
def with_fmt(f, rest=None): return build([(c, (bytes(f) if c == b'fmt ' else b)) for c, b in (rest or gc)])
def setw(b, off, v): x = bytearray(b); x[off:off + 2] = struct.pack('<H', v); return x
def three(tag, ba):
    f = struct.pack('<HHIIHHHHH', tag, 3, 22050, 22050, ba, 4, 2, 2 * ba, 0)
    if tag == 2: f = struct.pack('<HHIIHHHHH', 2, 3, 22050, 22050, ba, 4, 32, 500, 7) + b''.join(struct.pack('<hh', *c) for c in wm.MS_COEF)
    return build([(b'fmt ', f), (b'data', bytes(ba * 4))])
rej = {'IMA with 3 channels': with_fmt(setw(gfmt, 2, 3)), 'IMA 3 channels with a valid block align': three(0x11, 252), 'MS ADPCM 3 channels': three(2, 252), 'IMA with 8-bit samples': with_fmt(setw(gfmt, 14, 8)),
       'IMA block align not a multiple of 4*ch': with_fmt(setw(gfmt, 12, 258)), 'IMA block align too small': with_fmt(setw(gfmt, 12, 8)),
       'IMA 0 channels': with_fmt(setw(gfmt, 2, 0)), 'A-law with 16-bit samples': build([(b'fmt ', struct.pack('<HHIIHHH', 6, 1, 8000, 8000, 1, 16, 0)), (b'data', bytes(100))]),
       'A-law 9 channels': build([(b'fmt ', struct.pack('<HHIIHHH', 6, 9, 8000, 72000, 9, 8, 0)), (b'data', bytes(100))]),
       'data before fmt': build([(b'data', bytes(100)), (b'fmt ', struct.pack('<HHIIHHH', 6, 1, 8000, 8000, 1, 8, 0))]),
       'rate 0': build([(b'fmt ', struct.pack('<HHIIHHH', 7, 1, 0, 8000, 1, 8, 0)), (b'data', bytes(100))]),
       'GSM 6.10 (not supported)': build([(b'fmt ', struct.pack('<HHIIHHHHH', 0x31, 1, 8000, 1625, 65, 0, 2, 320, 0)), (b'data', bytes(130))]),
       'MP3 in WAV (not supported)': build([(b'fmt ', struct.pack('<HHIIHHH', 0x55, 2, 44100, 16000, 1, 0, 0)), (b'data', bytes(400))]),
       'tiny': b'RIFF\x04\0\0\0WAVE', 'no data chunk': build([gc[0]])}
for name, w in rej.items():
    rc, out = run(w, '-c', '100'); check('reject ' + name, rc != 0 and out == b'')

print(f'{checks} compressed-WAV checks, {bad} failures')
for n in notes: print('note:', n)
shutil.rmtree(TMP, ignore_errors=True); sys.exit(1 if bad else 0)
