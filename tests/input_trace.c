// Test-only link wrapper: observe events at the real engine input boundary.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include "doomgeneric.h"

int __real_DG_GetKey(int *pressed, unsigned char *key);
int __wrap_DG_GetKey(int *pressed, unsigned char *key)
{
    static FILE *trace;
    if (!trace) {
        trace = fopen(getenv("DOOM_INPUT_TRACE"), "w");
        if (!trace) abort();
        setvbuf(trace, NULL, _IONBF, 0);
    }
    int found = __real_DG_GetKey(pressed, key);
    if (found) fprintf(trace, "%u %d %u\n", DG_GetTicksMs(), *pressed, *key);
    return found;
}
