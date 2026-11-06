/*
 * Decoder seek check: link against build/codecs.o (make).
 *
 * Decodes a whole file, then seeks to several positions and checks that the
 * samples read there are bit-for-bit the ones from the straight decode.
 *
 *   codec_seek FILE   prints "exact=N/7 frames=F"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int type; void *h; unsigned rate, ch; unsigned long long total; } dec_t;
int codec_open(dec_t *, const unsigned char *, size_t);
size_t codec_read(dec_t *, short *, size_t);
void codec_seek(dec_t *, unsigned long long);
void codec_close(dec_t *);

int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    unsigned char *p = malloc(n);
    if (fread(p, 1, n, f) != (size_t)n) return 2;

    dec_t d;
    if (!codec_open(&d, p, n)) { puts("error=cannot open"); return 1; }
    size_t tot = d.total * d.ch;
    short *all = malloc(tot * 2);
    size_t got = 0, r;
    while (got < d.total && (r = codec_read(&d, all + got * d.ch, 4096))) got += r;

    unsigned long long at[] = {12345, 1000000, 5000000, 8000000, 13000000, 441, 7777777};
    int ok = 0, tried = 0;
    short buf[2048 * 8];
    for (int i = 0; i < 7; i++) {
        if (at[i] + 2048 > got) continue;
        tried++;
        codec_seek(&d, at[i]);
        if (codec_read(&d, buf, 2048) == 2048 &&
            !memcmp(buf, all + at[i] * d.ch, 2048 * d.ch * 2))
            ok++;
    }
    printf("exact=%d/%d frames=%zu\n", ok, tried, got);
    codec_close(&d);
    return ok == tried ? 0 : 1;
}
