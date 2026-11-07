/* peepdump [-C native|dr] [-g gain] [-c chunk] [-s seekframe] [-W] [-D mode] [-M type:index] [-E] [-R seed] file > out.raw
 *   default output stereo s16le; -W stereo int32 (peep_fill32); -D 0|1|2 16-bit mode for >16-bit sources;
 *   -M writes one FLAC metadata block to stdout; -E prints errors= and bits= to stderr at the end */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#include <sys/mman.h>
#endif
#include "peep.h"
#ifndef NO_DR
extern const peep_codec peep_codec_drflac;
#endif
#ifdef _WIN32
static int getopt(int argc, char **argv, const char *spec)     /* tiny getopt for the Windows build */
{
    extern char *optarg; extern int optind; static int init;
    if (!init) { optind = 1; init = 1; }
    if (optind >= argc || argv[optind][0] != '-') return -1;
    char c = argv[optind][1]; const char *p = strchr(spec, c);
    if (p && p[1] == ':') { optarg = argv[optind + 1]; optind += 2; } else optind++;
    return c;
}
char *optarg; int optind;
#endif
int main(int argc, char **argv)
{
    unsigned gain = 256; size_t chunk = 1024; long long seek = -1; int o; unsigned long long rnd = 0; int dr = 0, wide = 0, dither = 0, mtype = -1, mindex = 0, showerr = 0;
    while ((o = getopt(argc, argv, "g:c:s:C:WD:M:ER:")) != -1)
        if (o == 'g') gain = atoi(optarg); else if (o == 'c') chunk = atol(optarg);
        else if (o == 's') seek = atoll(optarg); else if (o == 'C') dr = !strcmp(optarg, "dr");
        else if (o == 'W') wide = 1; else if (o == 'D') dither = atoi(optarg); else if (o == 'E') showerr = 1;
        else if (o == 'R') rnd = strtoull(optarg, 0, 10) * 2654435761ull + 1;
        else if (o == 'M') sscanf(optarg, "%d:%d", &mtype, &mindex);
    if (optind >= argc) return 2;
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    FILE *fh = fopen(argv[optind], "rb"); struct stat st;
    if (!fh || stat(argv[optind], &st) || st.st_size == 0) { fprintf(stderr, "cannot read\n"); return 3; }
    void *d = malloc(st.st_size); if (fread(d, 1, st.st_size, fh) != (size_t)st.st_size) return 3; fclose(fh);
#else
    int fd = open(argv[optind], O_RDONLY); struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size == 0) { fprintf(stderr, "cannot read\n"); return 3; }
    void *d = mmap(0, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
#endif
    static const peep_codec *const native[] = { &peep_codec_wavc, &peep_codec_wavx, &peep_codec_flac, 0 };
#ifndef NO_DR
    static const peep_codec *const drc[]    = { &peep_codec_wavc, &peep_codec_wavx, &peep_codec_drflac, 0 };
#else
    static const peep_codec *const drc[]    = { &peep_codec_wavc, &peep_codec_wavx, &peep_codec_flac, 0 };
#endif
    peep p; void *work = NULL; size_t wsize = 0;
    if (!peep_open(&p, dr ? drc : native, d, st.st_size, work, wsize)) {
        if (!p.work_need) { fprintf(stderr, "REJECTED\n"); return 1; }
        work = calloc(1, wsize = p.work_need);                 /* the codec asked for memory */
        if (!peep_open(&p, dr ? drc : native, d, st.st_size, work, wsize)) { fprintf(stderr, "REJECTED\n"); return 1; }
    }
    fprintf(stderr, "kind=%u rate=%u ch=%u total=%llu work=%zu\n", p.kind, p.rate, p.channels, (unsigned long long)p.total, wsize);
    if (mtype >= 0) {
        const void *blk = 0; size_t len = peep_flac_metadata(&p, mtype, mindex, &blk);
        if (len == (size_t)-1) return 5;
        if (len) fwrite(blk, 1, len, stdout);
        peep_close(&p); return 0;
    }
    peep_set_gain(&p, gain); peep_set_dither(&p, dither);
    if (seek >= 0) peep_seek(&p, seek);
    int16_t *buf = malloc(chunk * 8 + 64); size_t n;
#define NEXT() (rnd ? (rnd ^= rnd << 13, rnd ^= rnd >> 7, rnd ^= rnd << 17, (rnd & 3) == 0 ? 1 : 1 + rnd % chunk) : chunk)   /* -R: a different request size every call, like a real callback */
    if (wide) while ((n = peep_fill32(&p, (int32_t *)buf, NEXT())) > 0) fwrite(buf, 8, n, stdout);
    else      while ((n = peep_fill(&p, buf, NEXT())) > 0) fwrite(buf, 4, n, stdout);
    if (showerr) fprintf(stderr, "errors=%u bits=%u\n", p.errors, p.bits);
    peep_close(&p); free(buf); free(work);
#ifndef _WIN32
    munmap(d, st.st_size);
#endif
    return 0;
}
