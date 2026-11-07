/* peepdump [-C native|dr] [-g gain] [-c chunk] [-s seekframe] file > out.raw   (stereo s16le) */
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
    unsigned gain = 256; size_t chunk = 1024; long long seek = -1; int o; int dr = 0;
    while ((o = getopt(argc, argv, "g:c:s:C:")) != -1)
        if (o == 'g') gain = atoi(optarg); else if (o == 'c') chunk = atol(optarg);
        else if (o == 's') seek = atoll(optarg); else dr = !strcmp(optarg, "dr");
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
    static const peep_codec *const native[] = { &peep_codec_flac, 0 };
#ifndef NO_DR
    static const peep_codec *const drc[]    = { &peep_codec_drflac, 0 };
#else
    static const peep_codec *const drc[]    = { &peep_codec_flac, 0 };
#endif
    peep p; void *work = NULL; size_t wsize = 0;
    if (!peep_open(&p, dr ? drc : native, d, st.st_size, work, wsize)) {
        if (!p.work_need) { fprintf(stderr, "REJECTED\n"); return 1; }
        work = calloc(1, wsize = p.work_need);                 /* the codec asked for memory */
        if (!peep_open(&p, dr ? drc : native, d, st.st_size, work, wsize)) { fprintf(stderr, "REJECTED\n"); return 1; }
    }
    fprintf(stderr, "kind=%u rate=%u ch=%u total=%llu work=%zu\n", p.kind, p.rate, p.channels, (unsigned long long)p.total, wsize);
    peep_set_gain(&p, gain);
    if (seek >= 0) peep_seek(&p, seek);
    int16_t *buf = malloc(chunk * 4 + 64); size_t n;
    while ((n = peep_fill(&p, buf, chunk)) > 0) fwrite(buf, 4, n, stdout);
    peep_close(&p); free(buf); free(work);
#ifndef _WIN32
    munmap(d, st.st_size);
#endif
    return 0;
}
