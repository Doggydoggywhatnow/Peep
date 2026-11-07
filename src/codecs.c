/*
 * Peep — codec shim.
 *
 * This is the only C in Peep. It exists so the assembly can call
 * well-tested public-domain libraries through one tiny API:
 *   - audio: dr_mp3, stb_vorbis (MP3 and Ogg Vorbis; core.asm plugs this in
 *     behind its native decoders, which do every PCM and float WAV and FLAC)
 *   - cover art: stb_image (JPEG, PNG, BMP, GIF)
 *   - custom fonts: stb_truetype (TTF, OTF, TTC)
 * Everything else — windowing, drag & drop, playlists, tag parsing, audio
 * output, mixing, image scaling, text layout, rendering, input — is
 * hand-written assembly in src/*.asm.
 *
 * Build `make pure` to leave this file out entirely: Peep then plays WAV and
 * FLAC with its own assembly decoders and nothing else.
 *
 * Decoding happens entirely from memory (the assembly maps the file), so no
 * stdio is compiled in.
 */
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#include "../third_party/stb_image.h"
#include <math.h>
/* glibc 2.38 re-versioned fmod; keep the AppImage runnable on older systems */
static double peep_fmod(double x, double y) { return x - trunc(x / y) * y; }
#define STBTT_fmod(x, y) peep_fmod(x, y)
#define STB_TRUETYPE_IMPLEMENTATION
#include "../third_party/stb_truetype.h"
#include "../third_party/dr_mp3.h"
#include "../third_party/stb_vorbis.c"

#include <stdlib.h>
#include <string.h>

/* Layout mirrored by DEC_* in src/abi.inc (core.asm reads rate, ch, total). Do not reorder. */
typedef struct {
    int                type;   /* 0  */
    void              *h;      /* 8  */
    unsigned           rate;   /* 16 */
    unsigned           ch;     /* 20 */
    unsigned long long total;  /* 24 */
} dec_t;

enum { T_MP3 = 2, T_OGG = 4 };

int codec_open(dec_t *d, const unsigned char *p, size_t n)
{
    d->type = 0;
    if (n >= 4 && !memcmp(p, "OggS", 4)) {
        int err;
        stb_vorbis *v = stb_vorbis_open_memory(p, (int)n, &err, NULL);
        if (!v) return 0;
        stb_vorbis_info i = stb_vorbis_get_info(v);
        d->h = v; d->rate = i.sample_rate; d->ch = i.channels;
        d->total = stb_vorbis_stream_length_in_samples(v); d->type = T_OGG;
        return 1;
    }
    /* Anything else: try MP3 (handles ID3 tags and raw frame sync). */
    drmp3 *m = malloc(sizeof *m);
    if (!m) return 0;
    if (!drmp3_init_memory(m, p, n, NULL)) { free(m); return 0; }
    d->h = m; d->rate = m->sampleRate; d->ch = m->channels;
    d->total = drmp3_get_pcm_frame_count(m); d->type = T_MP3;
    return 1;
}

size_t codec_read(dec_t *d, short *out, size_t frames)
{
    switch (d->type) {
    case T_MP3:  return (size_t)drmp3_read_pcm_frames_s16(d->h, frames, out);
    case T_OGG:  return (size_t)stb_vorbis_get_samples_short_interleaved(
                         d->h, (int)d->ch, out, (int)(frames * d->ch));
    }
    return 0;
}

/* MP3 seek index, one point per second, built in a single pass over the
 * frame headers the first time the track is seeked. Without it every
 * backward seek decodes the file again from the start (~200 ms into a
 * 5-minute track, seconds into an hour-long one). Building it lazily keeps
 * opening a track free; dr_mp3's own builder also makes a second counting
 * pass and decodes back to the old position, which this skips. */
static drmp3_uint64 mp3_index(drmp3 *m)  /* -> PCM frames in the stream */
{
    drmp3__seeking_mp3_frame_info fi[DRMP3_SEEK_LEADING_MP3_FRAMES + 1];
    drmp3_uint32 nfi = 0, n = 0, cap = 0;
    drmp3_uint64 pcm = 0, mp3n = 0, step = m->sampleRate ? m->sampleRate : 44100;
    drmp3_uint64 next = step;
    float frac = 0;
    drmp3_seek_point *sp = NULL;

    if (!drmp3_seek_to_start_of_stream(m)) return 0;
    for (;;) {
        drmp3_uint32 got;
        if (nfi == DRMP3_COUNTOF(fi)) {
            memmove(fi, fi + 1, sizeof fi - sizeof fi[0]);
            nfi--;
        }
        fi[nfi].bytePos       = m->streamCursor - m->dataSize;
        fi[nfi].pcmFrameIndex = pcm;
        fi[nfi].mp3FrameIndex = mp3n;
        got = drmp3_decode_next_frame_ex(m, NULL, NULL, NULL);   /* headers only */
        if (got == 0) break;
        nfi++;
        mp3n += 1 + m->mp3FramesSkipped;
        drmp3__accumulate_running_pcm_frame_count(m, got, &pcm, &frac);
        while (next < pcm) {               /* `next` lies in the newest frame */
            if (n == cap) {
                drmp3_seek_point *g = realloc(sp, (cap = cap ? cap * 2 : 512) * sizeof *sp);
                if (!g) { free(sp); sp = NULL; n = cap = 0; next = ~(drmp3_uint64)0; continue; }
                sp = g;
            }
            sp[n].seekPosInBytes     = fi[0].bytePos;
            sp[n].pcmFrameIndex      = next;
            sp[n].mp3FramesToDiscard = (drmp3_uint16)(fi[nfi-1].mp3FrameIndex - fi[0].mp3FrameIndex);
            sp[n].pcmFramesToDiscard = (drmp3_uint16)(next - fi[nfi-1].pcmFrameIndex);
            n++;
            next += step;
        }
    }
    if (!(n && drmp3_bind_seek_table(m, n, sp))) free(sp);
    return pcm;
}

void codec_seek(dec_t *d, unsigned long long frame)
{
    switch (d->type) {
    case T_MP3:
        if (!((drmp3 *)d->h)->pSeekPoints) mp3_index(d->h);
        drmp3_seek_to_pcm_frame(d->h, frame);
        break;
    case T_OGG:  stb_vorbis_seek(d->h, (unsigned)frame); break;
    }
}

void codec_close(dec_t *d)
{
    switch (d->type) {
    case T_MP3:  { void *sp = ((drmp3 *)d->h)->pSeekPoints;
                   drmp3_uninit(d->h); free(sp); free(d->h); break; }
    case T_OGG:  stb_vorbis_close(d->h); break;
    }
    d->type = 0;
    d->h = 0;
}

/* ---- cover art ---------------------------------------------------------- */
unsigned char *image_decode(const unsigned char *p, size_t n, int *w, int *h)
{
    int c;
    if (n > 0x7fffffff) return NULL;
    return stbi_load_from_memory(p, (int)n, w, h, &c, 4);   /* RGBA */
}
void image_free(void *p) { stbi_image_free(p); }

/* ---- fonts ---------------------------------------------------------------
 * Sizes cross the boundary as pixels; advances as 26.6 fixed point. */
void *font_load(const unsigned char *p, size_t n)
{
    stbtt_fontinfo *f;
    int off = stbtt_GetFontOffsetForIndex(p, 0);
    if (off < 0 || (size_t)off >= n) return NULL;
    f = malloc(sizeof *f);
    if (!f) return NULL;
    if (!stbtt_InitFont(f, p, off)) { free(f); return NULL; }
    return f;
}
void font_free(void *f) { free(f); }

int font_ascent(void *f, int px)
{
    int a, d, g;
    stbtt_GetFontVMetrics(f, &a, &d, &g);
    return (int)(a * stbtt_ScaleForPixelHeight(f, (float)px) + 0.5f);
}
int font_advance(void *f, int cp, int px)
{
    int adv, lsb;
    stbtt_GetCodepointHMetrics(f, cp, &adv, &lsb);
    return (int)(adv * stbtt_ScaleForPixelHeight(f, (float)px) * 64.0f + 0.5f);
}
int font_kern(void *f, int a, int b, int px)
{
    return (int)(stbtt_GetCodepointKernAdvance(f, a, b) *
                 stbtt_ScaleForPixelHeight(f, (float)px) * 64.0f);
}
/* out[0..3] = width, height, xoff, yoff. Returns an 8-bit coverage bitmap. */
unsigned char *font_glyph(void *f, int cp, int px, int *out)
{
    float s = stbtt_ScaleForPixelHeight(f, (float)px);
    return stbtt_GetCodepointBitmap(f, 0, s, cp, &out[0], &out[1], &out[2], &out[3]);
}
void font_glyph_free(void *b) { stbtt_FreeBitmap(b, NULL); }
