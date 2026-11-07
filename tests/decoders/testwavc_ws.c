/* testwavc_ws: the workspace protocol of the compressed-WAV codec. ADPCM needs 80 bytes of workspace and must say so (work_need = 80) when it
 * gets none or too little; A-law and mu-law need none. With the workspace the output must not depend on how big it is (80 or more), and an
 * undersized one (79) must be refused, not used.   testwavc_ws FILE...  (exit status 0 = ok) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include "peep.h"

static int bad, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { bad++; printf("FAIL %s: ", name); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char **argv)
{
    static const peep_codec *const codecs[] = { &peep_codec_wavc, 0 };
    for (int i = 1; i < argc; i++) {
        const char *name = argv[i]; int fd = open(name, O_RDONLY); struct stat st;
        if (fd < 0 || fstat(fd, &st)) continue;
        unsigned char *d = malloc(st.st_size); if (read(fd, d, st.st_size) != st.st_size) return 3; close(fd);
        peep p; static int16_t ref[1 << 16], out[1 << 16];
        int ok0 = peep_open(&p, codecs, d, st.st_size, NULL, 0); size_t need = p.work_need;
        if (ok0) {                                         /* no workspace needed: A-law / mu-law */
            CHECK(need == 0, "opened without a workspace but work_need = %zu", need);
        } else {                                           /* ADPCM: it must ask for exactly 80 bytes */
            CHECK(need == 80, "work_need = %zu, expected 80", need);
            unsigned char *w = calloc(1, 4096);
            CHECK(!peep_open(&p, codecs, d, st.st_size, w, 79), "an undersized workspace (79 bytes) was accepted");
            CHECK(!peep_open(&p, codecs, d, st.st_size, NULL, 80), "a NULL workspace with work_size 80 was accepted");
            CHECK(peep_open(&p, codecs, d, st.st_size, w, 80), "an 80-byte workspace was refused");
            size_t n1 = peep_fill(&p, ref, 4096); peep_close(&p);
            unsigned char *w2 = malloc(4096); memset(w2, 0xA5, 4096);                /* a bigger, dirty workspace gives the same samples */
            CHECK(peep_open(&p, codecs, d, st.st_size, w2, 4096), "a 4096-byte workspace was refused");
            size_t n2 = peep_fill(&p, out, 4096);
            CHECK(n1 == n2 && memcmp(ref, out, n1 * 4) == 0, "output differs between workspaces (%zu vs %zu frames)", n1, n2);
            peep_seek(&p, 700); size_t n3 = peep_fill(&p, out, 50); peep_seek(&p, 0); peep_fill(&p, out + 4096, 700); peep_seek(&p, 700);
            size_t n4 = peep_fill(&p, out + 8192, 50);
            CHECK(n3 == n4 && memcmp(out, out + 8192, n3 * 4) == 0, "seeking back to 700 gave different samples");
            free(w); free(w2);
        }
        free(d);
    }
    printf("testwavc_ws: %d checks, %d failures\n", checks, bad);
    return bad != 0;
}
