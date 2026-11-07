"""Independent models of the compressed WAV formats (A-law, mu-law, IMA ADPCM, Microsoft ADPCM), written from the format
descriptions and checked against ffmpeg's decoder. Used by testwavc.py as the expected output."""
import struct
import numpy as np

IMA_STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
            130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
            1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
            8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]
IMA_INDEX = [-1, -1, -1, -1, 2, 4, 6, 8]
MS_ADAPT = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]
MS_COEF = [(256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232)]

def alaw(b):
    a = b ^ 0x55; t = (a & 0xF) << 4; seg = (a & 0x70) >> 4
    if seg == 0: t += 8
    else: t = (t + 0x108) << (seg - 1)
    return t if a & 0x80 else -t

def ulaw(b):
    u = ~b & 0xFF; t = (((u & 0xF) << 3) + 0x84) << ((u & 0x70) >> 4)
    return (0x84 - t) if u & 0x80 else (t - 0x84)

ALAW = np.array([alaw(i) for i in range(256)], dtype=np.int64)
ULAW = np.array([ulaw(i) for i in range(256)], dtype=np.int64)

def clamp16(v): return -32768 if v < -32768 else 32767 if v > 32767 else v

def ima_frames_in(rem, ch, spb):
    """frames held by `rem` bytes of data (whole blocks plus a partial last block)"""
    return None

def ima_decode(data, ch, ba):
    """-> int64 array (frames, ch). Whole blocks, then the groups of a partial last block that are present."""
    spb = (ba - 4 * ch) * 2 // ch + 1; out = []
    pos = 0
    while pos + 4 * ch <= len(data):
        blk = data[pos:pos + ba]; pos += ba
        pred = [struct.unpack('<h', blk[4 * c:4 * c + 2])[0] for c in range(ch)]
        idx = [min(88, blk[4 * c + 2]) for c in range(ch)]
        frames = [list(pred)]
        groups = (len(blk) - 4 * ch) // (4 * ch)
        for g in range(groups):
            cols = [[] for _ in range(ch)]
            for c in range(ch):
                base = 4 * ch + (g * ch + c) * 4
                for k in range(8):
                    byte = blk[base + (k >> 1)]; nib = (byte >> 4) if k & 1 else (byte & 15)
                    step = IMA_STEP[idx[c]]; diff = step >> 3
                    if nib & 1: diff += step >> 2
                    if nib & 2: diff += step >> 1
                    if nib & 4: diff += step
                    if nib & 8: diff = -diff
                    pred[c] = clamp16(pred[c] + diff); idx[c] = max(0, min(88, idx[c] + IMA_INDEX[nib & 7]))
                    cols[c].append(pred[c])
            for k in range(8): frames.append([cols[c][k] for c in range(ch)])
        out += frames
    return np.array(out, dtype=np.int64).reshape(-1, ch)

def ms_decode(data, ch, ba, coefs=MS_COEF):
    out = []; pos = 0
    while pos + 7 * ch <= len(data):
        blk = data[pos:pos + ba]; pos += ba
        pi = [min(blk[c], len(coefs) - 1) for c in range(ch)]
        delta = [struct.unpack('<h', blk[ch + 2 * c:ch + 2 * c + 2])[0] for c in range(ch)]
        s1 = [struct.unpack('<h', blk[3 * ch + 2 * c:3 * ch + 2 * c + 2])[0] for c in range(ch)]
        s2 = [struct.unpack('<h', blk[5 * ch + 2 * c:5 * ch + 2 * c + 2])[0] for c in range(ch)]
        out.append(list(s2)); out.append(list(s1))
        body = blk[7 * ch:]
        def nibble(c, n):
            c1, c2 = coefs[pi[c]]; t = s1[c] * c1 + s2[c] * c2
            pred = -((-t) // 256) if t < 0 else t // 256            # integer division truncating toward zero
            v = clamp16(pred + (n - 16 if n & 8 else n) * delta[c])
            s2[c] = s1[c]; s1[c] = v; delta[c] = max(16, (MS_ADAPT[n] * delta[c]) >> 8)
            return v
        if ch == 1:
            for byte in body: out.append([nibble(0, byte >> 4)]); out.append([nibble(0, byte & 15)])
        else:
            for byte in body: l = nibble(0, byte >> 4); r = nibble(1, byte & 15); out.append([l, r])
    return np.array(out, dtype=np.int64).reshape(-1, ch)

def parse_wav(d):
    """-> (fmt dict, data bytes, fact or None)"""
    i = 12; fmt = None; data = b''; fact = None
    while i + 8 <= len(d):
        cid = d[i:i + 4]; sz = struct.unpack('<I', d[i + 4:i + 8])[0]; body = d[i + 8:i + 8 + sz]
        if cid == b'fmt ': fmt = dict(tag=struct.unpack('<H', body[:2])[0], ch=struct.unpack('<H', body[2:4])[0],
                                      rate=struct.unpack('<I', body[4:8])[0], ba=struct.unpack('<H', body[12:14])[0], raw=body)
        elif cid == b'fact': fact = struct.unpack('<I', body[:4])[0]
        elif cid == b'data': data = body; break
        i += 8 + sz + (sz & 1)
    return fmt, data, fact
