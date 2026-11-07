/* Liberated Peep (lib-Peep): Peep's playback kernel as a library.  "Audio for All"
 * Version 0.5.0, built from Peep 0.2.11. x86-64 and ARM64. Public domain (Unlicense), see LICENSE.
 *
 * Freestanding x86-64 assembly: no libc, no malloc, no threads, no OS calls.
 * You own all memory. Pull-based: your audio callback calls peep_fill().
 *
 * Output is always interleaved stereo int16 at peep_rate(); the volume is a
 * q8 gain (0..256) applied in the same pass that reads the samples.
 * Built in: 16-bit PCM WAV (incl. WAVE_FORMAT_EXTENSIBLE), decoded straight
 * from your memory with no copy. Anything else comes from a plugged-in codec.
 */
#ifndef PEEP_H
#define PEEP_H
#include <stddef.h>
#include <stdint.h>
#define LIBPEEP_VERSION "0.5.0"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct peep peep;

/* A codec. Fill p->rate, p->channels (1..8) and p->total (frames, 0 = unknown)
 * in open(). p->ctx and p->state[] are yours; p->src/p->len are the file.
 * Also set p->bits (bits per sample of the source; 0 means 16).
 * read() returns interleaved int16 in the file's own channel count, up to
 * `frames` frames; 0 means end of stream. seek, close and read32 may be NULL.
 * Peep maps any channel count to stereo (mono is duplicated, 3+ uses the
 * first two channels). */
typedef struct peep_codec {
    int    (*open)(peep *p, const void *data, size_t len);  /* nonzero = mine */
    size_t (*read)(peep *p, int16_t *out, size_t frames);
    void   (*seek)(peep *p, uint64_t frame);   /* may be NULL */
    void   (*close)(peep *p);                  /* may be NULL */
    /* Optional (NULL = not offered): the same frames at full resolution, as int32, each sample
     * left-justified (value << (32 - bits)), in the file's own channel count. A codec that sets
     * p->bits above 16 should provide it: peep_fill32() and the cleaner 16-bit output use it. */
    size_t (*read32)(peep *p, int32_t *out, size_t frames);
} peep_codec;

/* 160 bytes. The fields are public: read them, and set only `gain`. */
struct peep {
    const peep_codec *codec;   /*   0  */
    const uint8_t    *src;     /*   8  the file in memory */
    size_t            len;     /*  16 */
    uint64_t          pos;     /*  24  frame cursor */
    uint64_t          total;   /*  32  frames, 0 = unknown */
    uint32_t          rate;    /*  40  Hz */
    uint32_t          channels;/*  44  of the source */
    uint32_t          gain;    /*  48  q8: 256 = unity, 0 = silence (max 256) */
    uint32_t          kind;    /*  52  0 closed, 1 built-in WAV, 2 codec */
    const uint8_t    *data;    /*  56  built-in WAV: first sample */
    void             *ctx;     /*  64  codec use */
    uint8_t           state[56]; /* 72  codec use */
    void             *work;    /* 128  workspace you lent to peep_open */
    size_t            work_size;/* 136 */
    size_t            work_need;/* 144 bytes a codec wanted; valid after a failed open */
    uint32_t          errors;  /* 152  damaged frames met so far (a codec adds to it) */
    uint16_t          dither;  /* 156  16-bit output for sources wider than 16 bits: 0 truncate, 1 round, 2 TPDF dither */
    uint16_t          bits;    /* 158  bits per sample of the source (WAV: 16) */
};

/* codecs: NULL-terminated array tried in order after the built-in WAV
 * (may be NULL). The memory at `data` must stay valid until peep_close().
 *
 * work, work_size: scratch memory for codecs that need some (FLAC needs
 * channels * max_blocksize * 4 + 16 bytes, typically 36 KB). It must stay valid until
 * peep_close(). Built-in WAV needs none. If a codec finds it too small, open
 * fails and p->work_need says how many bytes it wanted, so you can allocate
 * and call again.
 *
 * Returns 1 on success, 0 if no decoder accepts the data. */
int    peep_open (peep *p, const peep_codec *const *codecs, const void *data, size_t len,
                  void *work, size_t work_size);

/* Write up to `frames` stereo frames (4 bytes each) to `out`. Returns the
 * number written; 0 = end of stream. A short count before the end is
 * allowed, so fill the rest with silence if your callback needs it. */
size_t peep_fill (peep *p, int16_t *out, size_t frames);

void   peep_seek (peep *p, uint64_t frame);   /* clamps to the end */
void   peep_close(peep *p);

/* Native assembly FLAC (flac.asm), 4 to 31 bits per sample, 1 to 8 channels. */
extern const peep_codec peep_codec_flac;
/* WAV extension codec (wav.asm): unsigned 8-bit, 12/16/20/24/32-bit PCM and 32/64-bit float WAV that the built-in
 * 16-bit decoder does not take. Put it in the codecs list. No workspace needed. */
extern const peep_codec peep_codec_wavx;
const peep_codec *peep_wavx(void);
/* Compressed WAV codec (wavc.asm): A-law, mu-law, IMA ADPCM and Microsoft ADPCM (see the file's header for what is covered). Output is 16-bit
 * (p->bits = 16). ADPCM needs an 80-byte workspace (work_need protocol); A-law and mu-law need none. */
extern const peep_codec peep_codec_wavc;
const peep_codec *peep_wavc(void);
/* The same table's address, as a function: for languages whose FFI can call functions but not read data symbols. */
const peep_codec *peep_flac(void);

/* Full resolution: interleaved stereo int32, each sample left-justified (value << (32 - bits)), so a 24-bit
 * file arrives with all its bits and a 16-bit file as x << 16. Volume is applied at 64-bit precision;
 * nothing is rounded or dithered. Returns the frames written; 0 = end of stream. */
size_t peep_fill32(peep *p, int32_t *out, size_t frames);

/* Zero-copy access to a FLAC file's metadata blocks (0 STREAMINFO, 1 PADDING, 2 APPLICATION, 3 SEEKTABLE,
 * 4 VORBIS_COMMENT, 5 CUESHEET, 6 PICTURE). Returns the length of the index-th block of that type and stores its
 * address in *data (may be NULL), or returns (size_t)-1 if there is none or p is not a FLAC file. */
size_t peep_flac_metadata(peep *p, int type, int index, const void **data);

/* peep_fill() reduces sources wider than 16 bits to 16 bits: 0 truncates (the default, bit-exact for 16-bit
 * sources and cheapest), 1 rounds to nearest, 2 adds TPDF dither (the cleanest for a 16-bit device). The volume
 * is applied before the reduction, at full precision. Sources of 16 bits or less are never touched. */
static inline void peep_set_dither(peep *p, unsigned mode) { p->dither = (uint16_t)(mode > 2 ? 2 : mode); }

static inline void peep_set_gain(peep *p, unsigned q8) { p->gain = q8 > 256 ? 256 : q8; }

#ifdef __cplusplus
}
#endif
#endif
