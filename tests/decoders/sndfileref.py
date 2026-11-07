"""Decode a WAV with libsndfile (through ctypes) as an independent reference: -> (int16 array (frames, ch), rate) or None."""
import ctypes, ctypes.util
import numpy as np

class SFInfo(ctypes.Structure):
    _fields_ = [('frames', ctypes.c_longlong), ('samplerate', ctypes.c_int), ('channels', ctypes.c_int),
                ('format', ctypes.c_int), ('sections', ctypes.c_int), ('seekable', ctypes.c_int)]

def available():
    return ctypes.util.find_library('sndfile') is not None

def decode(path):
    lib = ctypes.CDLL(ctypes.util.find_library('sndfile'))
    lib.sf_open.restype = ctypes.c_void_p
    info = SFInfo(); h = lib.sf_open(path.encode(), 0x10, ctypes.byref(info))     # SFM_READ
    if not h: return None
    buf = np.zeros(info.frames * info.channels, dtype=np.int16)
    lib.sf_readf_short.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_longlong]
    got = lib.sf_readf_short(h, buf.ctypes.data, info.frames)
    lib.sf_close.argtypes = [ctypes.c_void_p]; lib.sf_close(h)
    return buf[:got * info.channels].astype(np.int64).reshape(-1, info.channels), info.samplerate
