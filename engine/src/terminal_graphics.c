// GPL-2.0. Kitty RGB images and Sixel images of DOOM's existing framebuffer.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "terminal_graphics.h"
#include "vendor/zlib/zlib.h"

struct stream { char **data; size_t *capacity; size_t used; };

static void append(struct stream *s, const void *data, size_t count)
{
    if (s->used + count > *s->capacity) {
        size_t size = (s->used + count) * 2;
        char *next = realloc(*s->data, size);
        if (!next) abort();
        *s->data = next;
        *s->capacity = size;
    }
    memcpy(*s->data + s->used, data, count);
    s->used += count;
}

static void text(struct stream *s, const char *value)
{
    append(s, value, strlen(value));
}

static void number(struct stream *s, unsigned value)
{
    char digits[16];
    int count = snprintf(digits, sizeof(digits), "%u", value);
    append(s, digits, (size_t)count);
}

static void kitty(struct stream *s, const pixel_t *screen, int cols, int rows)
{
    const size_t pixels = DOOMGENERIC_RESX * DOOMGENERIC_RESY;
    static unsigned char rgb[DOOMGENERIC_RESX * DOOMGENERIC_RESY * 3];
    for (size_t i = 0; i < pixels; i++) {
        rgb[i * 3] = (screen[i] >> 16) & 255;
        rgb[i * 3 + 1] = (screen[i] >> 8) & 255;
        rgb[i * 3 + 2] = screen[i] & 255;
    }
    uLongf length = compressBound(sizeof(rgb));
    unsigned char *compressed = malloc(length);
    if (!compressed) abort();
    if (compress2(compressed, &length, rgb, sizeof(rgb), 1) != Z_OK) abort();
    // Each independently base64-encoded chunk is a multiple of three bytes,
    // except the last. The protocol limits each payload to 4096 characters.
    const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t offset = 0; offset < length;) {
        size_t count = length - offset;
        if (count > 3072) count = 3072;
        char controls[160];
        int last = offset + count == length;
        if (!offset)
            snprintf(controls, sizeof(controls),
                     "\033_Ga=T,f=24,o=z,s=%d,v=%d,c=%d,r=%d,i=32,p=1,q=2,C=1,m=%d;",
                     DOOMGENERIC_RESX, DOOMGENERIC_RESY, cols, rows, !last);
        else
            snprintf(controls, sizeof(controls), "\033_Gm=%d;", !last);
        text(s, controls);
        for (size_t i = 0; i < count; i += 3) {
            unsigned bits = (unsigned)compressed[offset + i] << 16;
            if (i + 1 < count) bits |= (unsigned)compressed[offset + i + 1] << 8;
            if (i + 2 < count) bits |= compressed[offset + i + 2];
            char encoded[4] = {alphabet[bits >> 18], alphabet[(bits >> 12) & 63],
                               i + 1 < count ? alphabet[(bits >> 6) & 63] : '=',
                               i + 2 < count ? alphabet[bits & 63] : '='};
            append(s, encoded, sizeof(encoded));
        }
        text(s, "\033\\");
        offset += count;
    }
    free(compressed);
}

static void sixel_run(struct stream *s, unsigned char bits, unsigned count)
{
    char glyph = (char)(63 + bits);
    if (count > 3) {
        text(s, "!"); number(s, count); append(s, &glyph, 1);
    } else {
        while (count--) append(s, &glyph, 1);
    }
}

static void sixel(struct stream *s, const pixel_t *screen, int width, int height)
{
    // DOOM uses a 256-colour palette. Index exact framebuffer colours once,
    // then build six-row colour masks rather than scanning the whole image
    // separately for every colour. A 1024-slot hash table bounds lookup work.
    uint32_t palette[256], slots[1024];
    unsigned short indices[1024] = {0};
    unsigned char indexed[DOOMGENERIC_RESX * DOOMGENERIC_RESY];
    unsigned colours = 0;
    for (size_t i = 0; i < sizeof(indexed); i++) {
        uint32_t rgb = screen[i] & 0xffffff;
        unsigned slot = (rgb * 2654435761u) >> 22;
        while (indices[slot] && slots[slot] != rgb) slot = (slot + 1) & 1023;
        if (!indices[slot]) {
            if (colours == 256) abort();
            palette[colours] = slots[slot] = rgb;
            indices[slot] = ++colours;
        }
        indexed[i] = (unsigned char)(indices[slot] - 1);
    }
    text(s, "\033P0;1;0q\"1;1;"); number(s, width); text(s, ";"); number(s, height);
    for (unsigned colour = 0; colour < colours; colour++) {
        text(s, "#"); number(s, colour); text(s, ";2;");
        number(s, ((palette[colour] >> 16) & 255) * 100 / 255); text(s, ";");
        number(s, ((palette[colour] >> 8) & 255) * 100 / 255); text(s, ";");
        number(s, (palette[colour] & 255) * 100 / 255);
    }
    unsigned char *masks = calloc(colours, (size_t)width);
    if (!masks) abort();
    for (int y = 0; y < height; y += 6) {
        memset(masks, 0, colours * (size_t)width);
        unsigned char active[256] = {0};
        for (int bit = 0; bit < 6 && y + bit < height; bit++) {
            int source_y = (int)((int64_t)(y + bit) * DOOMGENERIC_RESY / height);
            for (int x = 0; x < width; x++) {
                int source_x = (int)((int64_t)x * DOOMGENERIC_RESX / width);
                unsigned colour = indexed[source_y * DOOMGENERIC_RESX + source_x];
                masks[colour * (size_t)width + x] |= 1 << bit;
                active[colour] = 1;
            }
        }
        for (unsigned colour = 0; colour < colours; colour++) {
            if (!active[colour]) continue;
            text(s, "#"); number(s, colour);
            unsigned char *line = masks + colour * (size_t)width;
            int end = width;
            while (end && !line[end - 1]) end--;
            for (int x = 0; x < end;) {
                int next = x + 1;
                while (next < end && line[next] == line[x]) next++;
                sixel_run(s, line[x], (unsigned)(next - x));
                x = next;
            }
            text(s, "$");
        }
        if (y + 6 < height) text(s, "-");
    }
    free(masks);
    text(s, "\033\\");
}

size_t terminal_image(enum graphics_mode mode, const pixel_t *screen,
                      int cols, int rows, int pixel_width, int pixel_height, int refresh_size,
                      char **output, size_t *capacity)
{
    struct stream s = {output, capacity, 0};
    static int sixel_mode_saved;
    if (mode == GRAPHICS_SIXEL && !sixel_mode_saved) {
        text(&s, "\033[?80s\033[?80l");
        sixel_mode_saved = 1;
    }
    if (mode == GRAPHICS_SIXEL && refresh_size) text(&s, "\033[14t");
    text(&s, "\033[?2026h\033[2J\033[H");
    if (mode == GRAPHICS_KITTY)
        kitty(&s, screen, cols, rows);
    else
        sixel(&s, screen, pixel_width, pixel_height);
    text(&s, "\033[?2026l");
    return s.used;
}
