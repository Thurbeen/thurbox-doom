// Test-only link wrapper: observe events at the real engine input boundary.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include "doomgeneric.h"
#include "d_event.h"
#include "doomkeys.h"
#include "doomstat.h"
#include "p_mobj.h"

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

void __real_G_Ticker(void);
void __wrap_G_Ticker(void)
{
    static FILE *ticks;
    if (!ticks) {
        ticks = fopen(getenv("DOOM_TICK_TRACE"), "w");
        if (!ticks) abort();
        setvbuf(ticks, NULL, _IONBF, 0);
    }
    __real_G_Ticker();
    fprintf(ticks, "%u %u\n", DG_GetTicksMs(),
            players[consoleplayer].mo ? players[consoleplayer].mo->angle : 0u);
}

void __real_DG_DrawFrame(void);
void __wrap_DG_DrawFrame(void)
{
    static FILE *frames;
    if (!frames) {
        frames = fopen(getenv("DOOM_FRAME_TRACE"), "w");
        if (!frames) abort();
        setvbuf(frames, NULL, _IONBF, 0);
    }
    uint32_t start = DG_GetTicksMs();
    __real_DG_DrawFrame();
    fprintf(frames, "%u %u\n", start, DG_GetTicksMs());
}
