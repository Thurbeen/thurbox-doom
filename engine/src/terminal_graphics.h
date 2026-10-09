// GPL-2.0: pixel rendering for a terminal that explicitly reports support.
#ifndef TERMINAL_GRAPHICS_H
#define TERMINAL_GRAPHICS_H
#include <stddef.h>
#include "doomgeneric.h"
enum graphics_mode { GRAPHICS_CELLS, GRAPHICS_SIXEL, GRAPHICS_KITTY };
size_t terminal_image(enum graphics_mode mode, const pixel_t *screen,
                      int cols, int rows, int pixel_width, int pixel_height, int refresh_size,
                      char **output, size_t *capacity);
#endif
