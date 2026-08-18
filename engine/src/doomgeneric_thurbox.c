// A doomgeneric frontend for a thurbox program pane.
//
// Copyright (C) 2026 Thurbeen
// Licensed under the GNU General Public License v2, like the doomgeneric and
// DOOM sources it is linked with. See LICENSE beside this file.
//
// It paints CELLS, because that is what a thurbox `surface` carries: the kernel
// runs this in a real terminal, parses its output with a vt100 parser and copies
// the resulting grid into the pane's rect. A terminal graphics protocol would
// have nothing to be parsed into, so every frame here is text — one `▀` per
// cell, the top pixel in the foreground colour and the bottom in the background,
// which is two vertical pixels per character.
//
// Three things in here are decisions rather than plumbing:
//
//   * FRAME DIFFING. A full 80x24 repaint is ~50 KB of escape sequences, and at
//     35 fps that is 1.7 MB/s through a pty and a parser. Only cells whose
//     colours changed are emitted, in runs, so a menu costs almost nothing and a
//     firefight costs what it has to.
//
//   * KEY RELEASE BY TIMING. thurbox cannot deliver key-release events: its
//     terminal layer asks for `DISAMBIGUATE_ESCAPE_CODES` and never
//     `REPORT_EVENT_TYPES`, and its event loop matches on press. A port that
//     waits for a release therefore latches every held key and walks you into a
//     wall. So a key is considered released once it has been quiet for
//     `-release` milliseconds, which is what terminal auto-repeat gives us:
//     while you hold it, presses keep arriving.
//
//   * NEAREST-NEIGHBOUR SCALING to the terminal's size, recomputed on SIGWINCH,
//     because the pane is resized by the kernel whenever the layout changes.

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "m_argv.h"

#define MAX_COLS 512
#define MAX_ROWS 256
#define EVENT_QUEUE 64
#define DEFAULT_RELEASE_MS 90

struct cell {
	unsigned char fr, fg, fb; // top pixel
	unsigned char br, bg, bb; // bottom pixel
};

struct event {
	int pressed;
	unsigned char key;
};

static struct termios entry_termios;
static int termios_saved = 0;

static int cols = 0, rows = 0;
static volatile sig_atomic_t resized = 1;

static struct cell *shadow = NULL; // what the terminal is already showing
static size_t shadow_cells = 0;
static int shadow_valid = 0;

static int col_of[MAX_COLS];      // cell column -> source x
static int row_of[MAX_ROWS * 2];  // pixel row   -> source y

static char *out = NULL;
static size_t out_size = 0;

static struct event queue[EVENT_QUEUE];
static int queue_head = 0, queue_tail = 0;

// Last time each DOOM key was seen pressed, and whether we have told DOOM it is
// down. The release is synthesised from these; see the note at the top.
static uint32_t key_seen[256];
static unsigned char key_down[256];
static uint32_t release_ms = DEFAULT_RELEASE_MS;

static void on_winch(int signum)
{
	(void)signum;
	resized = 1;
}

static void restore_terminal(void)
{
	if (termios_saved) {
		tcsetattr(STDIN_FILENO, TCSAFLUSH, &entry_termios);
		termios_saved = 0;
	}
	// Colours off, cursor back, and a clear so the pane is not left holding
	// half a frame.
	const char *bye = "\033[0m\033[?25h\033[2J\033[H";
	ssize_t ignored = write(STDOUT_FILENO, bye, strlen(bye));
	(void)ignored;
}

static void die(const char *message)
{
	restore_terminal();
	fprintf(stderr, "doom: %s\n", message);
	exit(1);
}

static void write_all(const char *buffer, size_t length)
{
	size_t sent = 0;
	while (sent < length) {
		ssize_t n = write(STDOUT_FILENO, buffer + sent, length - sent);
		if (n > 0) {
			sent += (size_t)n;
			continue;
		}
		if (n < 0 && (errno == EINTR || errno == EAGAIN))
			continue;
		return; // the pane went away; the next tick will notice
	}
}

// --- geometry ---------------------------------------------------------------

static void measure(void)
{
	struct winsize ws;
	int width = 80, height = 24;
	if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
		width = ws.ws_col;
		height = ws.ws_row;
	}
	if (width > MAX_COLS)
		width = MAX_COLS;
	if (height > MAX_ROWS)
		height = MAX_ROWS;
	cols = width;
	rows = height;

	for (int x = 0; x < cols; x++)
		col_of[x] = (int)((long)x * DOOMGENERIC_RESX / cols);
	for (int y = 0; y < rows * 2; y++)
		row_of[y] = (int)((long)y * DOOMGENERIC_RESY / (rows * 2));

	size_t needed = (size_t)cols * (size_t)rows;
	if (needed > shadow_cells) {
		free(shadow);
		shadow = calloc(needed, sizeof(*shadow));
		if (!shadow)
			die("out of memory for the frame buffer");
		shadow_cells = needed;
	}
	shadow_valid = 0;

	// Worst case per cell: a full fg+bg SGR pair plus the glyph, plus a cursor
	// move per run. 48 bytes is generous; the +1024 covers the frame's own
	// prologue and epilogue.
	size_t want = needed * 48 + 1024;
	if (want > out_size) {
		free(out);
		out = malloc(want);
		if (!out)
			die("out of memory for the output buffer");
		out_size = want;
	}
}

// --- the frame -------------------------------------------------------------

static char *put(char *at, const char *text)
{
	size_t n = strlen(text);
	memcpy(at, text, n);
	return at + n;
}

static char *put_uint(char *at, unsigned value)
{
	char digits[10];
	int n = 0;
	do {
		digits[n++] = (char)('0' + value % 10);
		value /= 10;
	} while (value);
	while (n--)
		*at++ = digits[n];
	return at;
}

void DG_DrawFrame(void)
{
	if (resized) {
		resized = 0;
		measure();
		// A resize invalidates everything the terminal was showing.
		out[0] = '\0';
		write_all("\033[2J", 4);
	}
	if (!shadow || cols <= 0 || rows <= 0)
		return;

	const pixel_t *screen = DG_ScreenBuffer;
	char *at = out;
	// Synchronised output, so a partially-written frame is never painted. The
	// kernel's parser handles the mode set like any other; a terminal that does
	// not know it ignores it.
	at = put(at, "\033[?2026h");

	int last_fg = -1, last_bg = -1; // what SGR state the stream is in
	for (int y = 0; y < rows; y++) {
		int run = 0; // is the cursor already where we want it?
		for (int x = 0; x < cols; x++) {
			const pixel_t top = screen[(size_t)row_of[y * 2] * DOOMGENERIC_RESX + col_of[x]];
			const pixel_t bottom = screen[(size_t)row_of[y * 2 + 1] * DOOMGENERIC_RESX + col_of[x]];
			struct cell want;
			want.fr = (top >> 16) & 0xff;
			want.fg = (top >> 8) & 0xff;
			want.fb = top & 0xff;
			want.br = (bottom >> 16) & 0xff;
			want.bg = (bottom >> 8) & 0xff;
			want.bb = bottom & 0xff;

			struct cell *have = &shadow[(size_t)y * cols + x];
			if (shadow_valid && memcmp(have, &want, sizeof(want)) == 0) {
				run = 0; // skipped a cell, so the cursor is stale
				continue;
			}
			*have = want;

			if (!run) {
				at = put(at, "\033[");
				at = put_uint(at, (unsigned)y + 1);
				*at++ = ';';
				at = put_uint(at, (unsigned)x + 1);
				*at++ = 'H';
				run = 1;
				last_fg = last_bg = -1; // be explicit after a jump
			}

			int fg = (want.fr << 16) | (want.fg << 8) | want.fb;
			int bg = (want.br << 16) | (want.bg << 8) | want.bb;
			if (fg != last_fg) {
				at = put(at, "\033[38;2;");
				at = put_uint(at, want.fr);
				*at++ = ';';
				at = put_uint(at, want.fg);
				*at++ = ';';
				at = put_uint(at, want.fb);
				*at++ = 'm';
				last_fg = fg;
			}
			if (bg != last_bg) {
				at = put(at, "\033[48;2;");
				at = put_uint(at, want.br);
				*at++ = ';';
				at = put_uint(at, want.bg);
				*at++ = ';';
				at = put_uint(at, want.bb);
				*at++ = 'm';
				last_bg = bg;
			}
			at = put(at, "▀"); // ▀ upper half block
		}
	}
	shadow_valid = 1;
	at = put(at, "\033[?2026l");
	write_all(out, (size_t)(at - out));
}

// --- time ------------------------------------------------------------------

uint32_t DG_GetTicksMs(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

void DG_SleepMs(uint32_t ms)
{
	struct timespec want;
	want.tv_sec = ms / 1000;
	want.tv_nsec = (long)(ms % 1000) * 1000000L;
	nanosleep(&want, NULL);
}

// --- input -----------------------------------------------------------------

static void push(int pressed, unsigned char key)
{
	int next = (queue_tail + 1) % EVENT_QUEUE;
	if (next == queue_head)
		return; // full: dropping is better than blocking the game
	queue[queue_tail].pressed = pressed;
	queue[queue_tail].key = key;
	queue_tail = next;
}

// A press, recorded so its release can be synthesised later.
static void press(unsigned char key)
{
	key_seen[key] = DG_GetTicksMs();
	if (!key_down[key]) {
		key_down[key] = 1;
		push(1, key);
	}
}

// Map one byte, or an escape sequence already recognised by the caller.
static void map_byte(unsigned char c)
{
	switch (c) {
	case '\r':
	case '\n':
		press(KEY_ENTER);
		return;
	case '\t':
		press(KEY_TAB);
		return;
	case 0x7f:
	case 0x08:
		press(KEY_BACKSPACE);
		return;
	case ' ':
		press(KEY_USE);
		return;
	case ',':
		press(KEY_STRAFE_L);
		return;
	case '.':
		press(KEY_STRAFE_R);
		return;
	case '+':
	case '=':
		press(KEY_EQUALS);
		return;
	case '-':
		press(KEY_MINUS);
		return;
	default:
		break;
	}
	// wasd alongside the arrows, since a terminal gives us letters more
	// reliably than it gives us anything else.
	switch (c) {
	case 'w':
	case 'W':
		press(KEY_UPARROW);
		return;
	case 's':
	case 'S':
		press(KEY_DOWNARROW);
		return;
	case 'a':
	case 'A':
		press(KEY_STRAFE_L);
		return;
	case 'd':
	case 'D':
		press(KEY_STRAFE_R);
		return;
	case 'q':
	case 'Q':
		press(KEY_LEFTARROW);
		return;
	case 'e':
	case 'E':
		press(KEY_RIGHTARROW);
		return;
	case 'f':
	case 'F':
		press(KEY_FIRE);
		return;
	case 'r':
	case 'R':
		press(KEY_RSHIFT); // run, since a bare shift never reaches us
		return;
	default:
		break;
	}
	if (c >= '0' && c <= '9') {
		press(c);
		return;
	}
	// Any other control byte is a fire: `ctrl` is DOOM's own fire key and a
	// terminal hands us the control code rather than the modifier.
	if (c < 32) {
		press(KEY_FIRE);
		return;
	}
	if (c < 128)
		press(c); // cheats, y/n prompts, and anything DOOM reads as a letter
}

static void read_input(void)
{
	unsigned char buffer[256];
	ssize_t n = read(STDIN_FILENO, buffer, sizeof(buffer));
	if (n <= 0)
		return;
	for (ssize_t i = 0; i < n; i++) {
		if (buffer[i] == 033) {
			// CSI or SS3 arrow, or a bare escape for the menu.
			if (i + 2 < n && (buffer[i + 1] == '[' || buffer[i + 1] == 'O')) {
				unsigned char final = buffer[i + 2];
				int handled = 1;
				switch (final) {
				case 'A':
					press(KEY_UPARROW);
					break;
				case 'B':
					press(KEY_DOWNARROW);
					break;
				case 'C':
					press(KEY_RIGHTARROW);
					break;
				case 'D':
					press(KEY_LEFTARROW);
					break;
				default:
					handled = 0;
					break;
				}
				if (handled) {
					i += 2;
					continue;
				}
				// Something longer we do not read: skip to its final byte
				// rather than feeding the parameters to DOOM as keystrokes.
				ssize_t j = i + 2;
				while (j < n && !(buffer[j] >= 0x40 && buffer[j] <= 0x7e))
					j++;
				i = j;
				continue;
			}
			press(KEY_ESCAPE);
			continue;
		}
		map_byte(buffer[i]);
	}
}

// Release anything that has been quiet long enough. This is the whole of the
// held-key story: auto-repeat keeps a held key arriving, so silence means it
// went up.
static void expire_keys(void)
{
	uint32_t now = DG_GetTicksMs();
	for (int key = 0; key < 256; key++) {
		if (!key_down[key])
			continue;
		if (now - key_seen[key] < release_ms)
			continue;
		key_down[key] = 0;
		push(0, (unsigned char)key);
	}
}

int DG_GetKey(int *pressed, unsigned char *key)
{
	if (queue_head == queue_tail) {
		read_input();
		expire_keys();
	}
	if (queue_head == queue_tail)
		return 0;
	*pressed = queue[queue_head].pressed;
	*key = queue[queue_head].key;
	queue_head = (queue_head + 1) % EVENT_QUEUE;
	return 1;
}

void DG_SetWindowTitle(const char *title)
{
	(void)title; // the pane draws its own border title
}

// --- lifecycle -------------------------------------------------------------

void DG_Init(void)
{
	if (!isatty(STDOUT_FILENO))
		die("this needs a terminal: run it in a thurbox pane, or a tty");

	if (tcgetattr(STDIN_FILENO, &entry_termios) == 0) {
		struct termios raw = entry_termios;
		raw.c_lflag &= (unsigned)~(ECHO | ICANON | ISIG);
		raw.c_iflag &= (unsigned)~(IXON | ICRNL);
		raw.c_cc[VMIN] = 0;  // never block: the game loop owns the clock
		raw.c_cc[VTIME] = 0;
		if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0)
			termios_saved = 1;
	}
	atexit(restore_terminal);
	signal(SIGWINCH, on_winch);
	// ISIG is off, so ctrl+c arrives as a byte rather than a signal; DOOM's own
	// menu is the way out, and the pane's own chord releases it.
	write_all("\033[?25l\033[2J", 10);
	measure();
}

int main(int argc, char **argv)
{
	// Our own arguments are read before doomgeneric sees them; it ignores what
	// it does not know, so they are simply passed through.
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-release") == 0 && i + 1 < argc) {
			long ms = strtol(argv[i + 1], NULL, 10);
			if (ms >= 0 && ms < 5000)
				release_ms = (uint32_t)ms;
		}
	}

	doomgeneric_Create(argc, argv);
	for (;;)
		doomgeneric_Tick();
	return 0;
}
