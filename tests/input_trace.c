// Test-only link wrapper: observe events at the real engine input boundary.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include "doomgeneric.h"
#include "d_event.h"
#include "doomkeys.h"

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

extern boolean menuactive;
boolean __real_M_Responder(event_t *event);
boolean __wrap_M_Responder(event_t *event)
{
    boolean handled = __real_M_Responder(event);
    if (event->type == ev_keydown && event->data1 == KEY_ESCAPE) {
        static FILE *menu;
        if (!menu) {
            menu = fopen(getenv("DOOM_MENU_TRACE"), "w");
            if (!menu) abort();
            setvbuf(menu, NULL, _IONBF, 0);
        }
        fprintf(menu, "%u %u\n", DG_GetTicksMs(), menuactive);
    }
    return handled;
}
