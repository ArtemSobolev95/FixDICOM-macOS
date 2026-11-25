// Prints what FDRepair finds in each file, and checks that a repaired file reads as complete.
#include "../Sources/FDRepair.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *names[] = { "OK", "NEEDS_FIX", "NOT_DICOM", "DAMAGED", "UNSUPPORTED" };
int main(int argc, char **argv)
{
    int bad = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb"); if (!f) { perror(argv[i]); return 2; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        unsigned char *b = malloc(n + 1024); fread(b, 1, n, f); fclose(f);
        fd_result r; fd_analyze(b, n, &r);
        printf("%-24s %-11s %s\n", strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i], names[r.status], r.message);
        if (r.status == FD_NEEDS_FIX) {
            memcpy(b + n, r.tail, r.tailLength);
            fd_result again; fd_analyze(b, n + r.tailLength, &again);
            if (again.status != FD_OK) { printf("   ** repaired file is still %s\n", names[again.status]); bad = 1; }
        }
        free(b);
    }
    return bad;
}
