/*
 * Decoder seek check.
 *
 * Decodes a whole file, then seeks to several positions and checks that the
 * samples read there are bit-for-bit the ones from the straight decode.
 *
 *   codec_seek kernel FILE   FLAC and WAV, through the assembly kernel (dec.o, flac.o)
 *   codec_seek shim FILE     MP3 and Ogg, through the C shim (codecs.o)
 *
 * Prints "exact=N/7 frames=F" and exits 0 only if every seek was exact.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "decoders/peep.h"

/* the C shim (src/codecs.c) */
typedef struct { int type; void *h; unsigned rate, ch; unsigned long long total; } dec_t;
int codec_open(dec_t *, const unsigned char *, size_t);
size_t codec_read(dec_t *, short *, size_t);
void codec_seek(dec_t *, unsigned long long);
void codec_close(dec_t *);

static const unsigned long long AT[] = {12345, 1000000, 5000000, 8000000, 13000000, 441, 7777777};

static int check(const short *all, unsigned long long got, unsigned ch,
                 size_t (*rd)(void *, short *, size_t), void (*sk)(void *, unsigned long long),
                 void *h)
{
    int ok = 0, tried = 0;
    static short buf[2048 * 8];
    for (int i = 0; i < 7; i++) {
        if (AT[i] + 2048 > got) continue;
        tried++;
        sk(h, AT[i]);
        if (rd(h, buf, 2048) == 2048 && !memcmp(buf, all + AT[i] * ch, 2048 * ch * 2)) ok++;
    }
    printf("exact=%d/%d frames=%llu\n", ok, tried, got);
    return ok == tried && tried > 0 ? 0 : 1;
}

/* ---- shim ---------------------------------------------------------------- */
static size_t sh_rd(void *h, short *o, size_t n) { return codec_read(h, o, n); }
static void sh_sk(void *h, unsigned long long f) { codec_seek(h, f); }
static int run_shim(const unsigned char *p, long n)
{
    dec_t d;
    if (!codec_open(&d, p, n)) { puts("error=cannot open"); return 1; }
    short *all = malloc(d.total * d.ch * 2);
    unsigned long long got = 0, r;
    while (got < d.total && (r = codec_read(&d, all + got * d.ch, 4096))) got += r;
    int rc = check(all, got, d.ch, sh_rd, sh_sk, &d);
    codec_close(&d);
    return rc;
}

/* ---- kernel (always stereo out) ---------------------------------------------- */
static size_t k_rd(void *h, short *o, size_t n) { return peep_fill(h, o, n); }
static void k_sk(void *h, unsigned long long f) { peep_seek(h, f); }
static int run_kernel(const unsigned char *d, long n)
{
    static const peep_codec *const codecs[] = {&peep_codec_flac, 0};
    peep p;
    void *work = NULL;
    if (!peep_open(&p, codecs, d, n, NULL, 0)) {
        size_t need = p.work_need;
        if (!need || !(work = calloc(1, need)) || !peep_open(&p, codecs, d, n, work, need)) {
            puts("error=cannot open");
            return 1;
        }
    }
    short *all = malloc((p.total ? p.total : 1) * 4);
    unsigned long long got = 0, r;
    while (got < p.total && (r = peep_fill(&p, all + got * 2, 4096))) got += r;
    int rc = check(all, got, 2, k_rd, k_sk, &p);
    peep_close(&p);
    return rc;
}

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    FILE *f = fopen(argv[2], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    unsigned char *p = malloc(n);
    if (fread(p, 1, n, f) != (size_t)n) return 2;
    return !strcmp(argv[1], "kernel") ? run_kernel(p, n) : run_shim(p, n);
}
