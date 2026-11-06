/*
 * Peep — codec shim.
 *
 * This is the only C in Peep. It exists so the assembly can call four
 * well-tested public-domain decoders (MP3, FLAC, Ogg Vorbis, and every WAV
 * flavour the assembly WAV decoder doesn't handle) through one tiny API.
 * Everything else — windowing, drag & drop, playlists, audio output,
 * mixing, rendering, input — is hand-written assembly in src/*.asm.
 *
 * Build `make pure` to leave this file out entirely: Peep then plays
 * 16-bit PCM WAV with its own assembly decoder and nothing else.
 *
 * Decoding happens entirely from memory (the assembly maps the file), so no
 * stdio is compiled in.
 */
#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "../third_party/dr_mp3.h"
#include "../third_party/dr_flac.h"
#include "../third_party/dr_wav.h"
#include "../third_party/stb_vorbis.c"

#include <stdlib.h>
#include <string.h>

/* Layout mirrored by DEC_* in src/abi.inc. Do not reorder. */
typedef struct {
    int                type;   /* 0  */
    void              *h;      /* 8  */
    unsigned           rate;   /* 16 */
    unsigned           ch;     /* 20 */
    unsigned long long total;  /* 24 */
} dec_t;

enum { T_MP3 = 2, T_FLAC = 3, T_OGG = 4, T_WAV = 5 };

int codec_open(dec_t *d, const unsigned char *p, size_t n)
{
    d->type = 0;
    if (n >= 4 && !memcmp(p, "fLaC", 4)) {
        drflac *f = drflac_open_memory(p, n, NULL);
        if (!f) return 0;
        d->h = f; d->rate = f->sampleRate; d->ch = f->channels;
        d->total = f->totalPCMFrameCount; d->type = T_FLAC;
        return 1;
    }
    if (n >= 4 && !memcmp(p, "OggS", 4)) {
        int err;
        stb_vorbis *v = stb_vorbis_open_memory(p, (int)n, &err, NULL);
        if (!v) return 0;
        stb_vorbis_info i = stb_vorbis_get_info(v);
        d->h = v; d->rate = i.sample_rate; d->ch = i.channels;
        d->total = stb_vorbis_stream_length_in_samples(v); d->type = T_OGG;
        return 1;
    }
    if (n >= 12 && (!memcmp(p, "RIFF", 4) || !memcmp(p, "RF64", 4) || !memcmp(p, "riff", 4))) {
        drwav *w = malloc(sizeof *w);
        if (!w) return 0;
        if (!drwav_init_memory(w, p, n, NULL)) { free(w); return 0; }
        d->h = w; d->rate = w->sampleRate; d->ch = w->channels;
        d->total = w->totalPCMFrameCount; d->type = T_WAV;
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
    case T_FLAC: return (size_t)drflac_read_pcm_frames_s16(d->h, frames, out);
    case T_WAV:  return (size_t)drwav_read_pcm_frames_s16(d->h, frames, out);
    case T_OGG:  return (size_t)stb_vorbis_get_samples_short_interleaved(
                         d->h, (int)d->ch, out, (int)(frames * d->ch));
    }
    return 0;
}

void codec_seek(dec_t *d, unsigned long long frame)
{
    switch (d->type) {
    case T_MP3:  drmp3_seek_to_pcm_frame(d->h, frame); break;
    case T_FLAC: drflac_seek_to_pcm_frame(d->h, frame); break;
    case T_WAV:  drwav_seek_to_pcm_frame(d->h, frame); break;
    case T_OGG:  stb_vorbis_seek(d->h, (unsigned)frame); break;
    }
}

void codec_close(dec_t *d)
{
    switch (d->type) {
    case T_MP3:  drmp3_uninit(d->h); free(d->h); break;
    case T_FLAC: drflac_close(d->h); break;
    case T_WAV:  drwav_uninit(d->h); free(d->h); break;
    case T_OGG:  stb_vorbis_close(d->h); break;
    }
    d->type = 0;
    d->h = 0;
}
