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
//   * REAL KEY RELEASES. Request Kitty keyboard flags 11 (disambiguation,
//     event types and all keys). Reported holds last until their release,
//     independent of desktop repeat delay. Keep partial sequences across reads.
//     A thurbox host must also request and forward release events; a modern
//     outer terminal alone cannot make them cross a press-only host.
//
//     Timing inference remains a compatibility fallback for a press-only
//     stream. Its 700 ms initial window bridges repeat delay but makes a tap
//     keep turning; once repeats arrive it shrinks to their measured interval.
//     No timeout can distinguish a tap from a hold before the first repeat.
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
// How long a lone press keeps a key down, before any auto-repeat has been seen for
// that key.
//
// It must outlast the initial repeat delay on EVERY hold. A press-only byte
// stream cannot distinguish a tap from a hold before repeats begin; -release
// controls that unavoidable tradeoff. Repeat intervals are learned per hold.
#define DEFAULT_RELEASE_MS 700
// A press this soon after the previous one is auto-repeat rather than a new tap.
#define REPEAT_MAX_GAP_MS 250
// The floor once the repeat rate is known: stopping should feel immediate.
#define MIN_RELEASE_MS 60

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
static size_t out_sent = 0, out_length = 0;

static struct event queue[EVENT_QUEUE];
static int queue_head = 0, queue_tail = 0;

// Last time each DOOM key was seen pressed, and whether we have told DOOM it is
// down. For unreported holds the release is synthesised from these.
static uint32_t key_seen[256];
// The auto-repeat interval measured for this key, or 0 while unknown. Learned rather
// than assumed: the rate is the user's setting, and once it is known the release
// window can be tight instead of conservative.
static uint32_t key_gap[256];
static unsigned char key_down[256];
static unsigned char key_reported[256]; // this hold has real release events
static int keyboard_events = 0;
// ASCII keys, four physical modifiers, and four arrows. Keep aliases held until
// their last physical source releases (e.g. w + Up, or r + Shift).
static uint16_t physical_key[136]; // DOOM key + 1; zero means released
static unsigned char physical_count[256];
static char input_sequence[64];
static size_t input_length = 0;
static uint32_t escape_seen = 0;
static uint32_t hold_ms = DEFAULT_RELEASE_MS;

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
	const char *bye = "\033[<u\033[0m\033[?25h\033[2J\033[H";
	ssize_t ignored = write(STDOUT_FILENO, bye, strlen(bye));
	(void)ignored;
}

static void die(const char *message)
{
	restore_terminal();
	fprintf(stderr, "doom: %s\n", message);
	exit(1);
}

// Finish a pending frame without waiting for the surface reader. Preserve its
// suffix, including any partial escape sequence, before building another frame.
static int flush_frame(void)
{
	while (out_sent < out_length) {
		ssize_t n = write(STDOUT_FILENO, out + out_sent, out_length - out_sent);
		if (n > 0) {
			out_sent += (size_t)n;
			continue;
		}
		if (n < 0 && errno == EINTR)
			continue;
		return 0;
	}
	out_sent = out_length = 0;
	return 1;
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
	// One pending frame bounds memory and backlog. If the reader is slow, skip
	// drawing this frame while the game continues ticking and accepting input.
	if (!flush_frame())
		return;
	int clear = 0;
	if (resized) {
		resized = 0;
		clear = 1;
		measure();
	}
	if (!shadow || cols <= 0 || rows <= 0)
		return;

	const pixel_t *screen = DG_ScreenBuffer;
	char *at = out;
	// Synchronised output, so a partially-written frame is never painted. The
	// kernel's parser handles the mode set like any other; a terminal that does
	// not know it ignores it.
	at = put(at, "\033[?2026h");
	if (clear)
		at = put(at, "\033[2J");

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
	out_length = (size_t)(at - out);
	flush_frame();
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
	// A buffered repeat burst needs one down event, not a queue full of the
	// same event. Separately polled presses still reach menus and shortcuts.
	if (pressed && queue_head != queue_tail) {
		int previous = (queue_tail + EVENT_QUEUE - 1) % EVENT_QUEUE;
		if (queue[previous].pressed && queue[previous].key == key)
			return;
	}
	int next = (queue_tail + 1) % EVENT_QUEUE;
	if (next == queue_head)
		return; // full: dropping is better than blocking the game
	queue[queue_tail].pressed = pressed;
	queue[queue_tail].key = key;
	queue_tail = next;
}

// A press, recorded so its release can be synthesised later.
//
// While a key is already down, the gap since its last press IS the terminal's
// auto-repeat interval, so it is worth learning: the shortest gap seen wins, since a
// scheduling hiccup can stretch one but nothing makes one shorter than the rate.
static void press(unsigned char key)
{
	uint32_t now = DG_GetTicksMs();
	if (key_down[key]) {
		uint32_t gap = now - key_seen[key];
		if (gap > 0 && gap <= REPEAT_MAX_GAP_MS && (key_gap[key] == 0 || gap < key_gap[key]))
			key_gap[key] = gap;
	}
	key_seen[key] = now;
	key_reported[key] = 0;
	int was_down = key_down[key];
	if (!was_down) {
		// A new hold has its own initial repeat delay. Reusing an old short
		// interval releases it before the first repeat can arrive.
		key_gap[key] = 0;
		key_down[key] = 1;
	}
	// DOOM's menu and automap consume keydown events, not held-key state.
	// Preserve each incoming press even while its inferred hold is active.
	// Shift is counted by I_GetEvent, so only its initial transition is sent.
	if (!was_down || key != KEY_RSHIFT)
		push(1, key);
}

// How long this key may stay down without another press.
//
// Two regimes, because the two silences mean different things. Before any repeat has
// arrived the silence might be the repeat DELAY — long, and the user's setting — so
// the window is `hold_ms` and a held key survives it. Once repeats are flowing, a
// silence longer than a couple of intervals can only mean the key came up, so the
// window collapses to that and stopping is immediate.
static uint32_t window_for(unsigned char key)
{
	uint32_t window;
	if (key_gap[key] == 0)
		return hold_ms;
	window = key_gap[key] * 2 + 20;
	if (window < MIN_RELEASE_MS)
		window = MIN_RELEASE_MS;
	if (window > hold_ms)
		window = hold_ms;
	return window;
}

// Map one byte, or an escape sequence already recognised by the caller.
static int key_for_byte(unsigned char c)
{
	switch (c) {
	case 033:
		return KEY_ESCAPE;
	case '\r':
	case '\n':
		return KEY_ENTER;
	case '\t':
		return KEY_TAB;
	case 0x7f:
	case 0x08:
		return KEY_BACKSPACE;
	case ' ':
		return KEY_USE;
	case ',':
		return KEY_STRAFE_L;
	case '.':
		return KEY_STRAFE_R;
	case '+':
	case '=':
		return KEY_EQUALS;
	case '-':
		return KEY_MINUS;
	default:
		break;
	}
	// wasd alongside the arrows, since a terminal gives us letters more
	// reliably than it gives us anything else.
	switch (c) {
	case 'w':
	case 'W':
		return KEY_UPARROW;
	case 's':
	case 'S':
		return KEY_DOWNARROW;
	case 'a':
	case 'A':
		return KEY_STRAFE_L;
	case 'd':
	case 'D':
		return KEY_STRAFE_R;
	case 'q':
	case 'Q':
		return KEY_LEFTARROW;
	case 'e':
	case 'E':
		return KEY_RIGHTARROW;
	case 'f':
	case 'F':
		return KEY_FIRE;
	case 'r':
	case 'R':
		return KEY_RSHIFT;
	default:
		break;
	}
	if (c >= '0' && c <= '9') {
		return c;
	}
	// Any other control byte is a fire: `ctrl` is DOOM's own fire key and a
	// terminal hands us the control code rather than the modifier.
	if (c < 32) {
		return KEY_FIRE;
	}
	if (c < 128)
		return c; // cheats, y/n prompts, and anything DOOM reads as a letter
	return -1;
}

static void map_byte(unsigned char c)
{
	int key = key_for_byte(c);
	if (key >= 0)
		press((unsigned char)key);
}

// Kitty keyboard protocol: event types 1/2/3 are press/repeat/release.
// https://sw.kovidgoyal.net/kitty/keyboard-protocol/
static void terminal_key(unsigned char key, int type, int reported, int identity)
{
	if (reported && identity >= 0) {
		uint16_t *source = &physical_key[identity];
		if (type == 3) {
			if (*source) {
				key = (unsigned char)(*source - 1);
				*source = 0;
				if (--physical_count[key])
					return;
			} else if (physical_count[key]) {
				return;
			}
		} else if (!*source) {
			*source = (uint16_t)key + 1;
			physical_count[key]++;
		} else {
			key = (unsigned char)(*source - 1);
		}
	}
	if (type == 3) {
		if (key_down[key]) {
			key_down[key] = key_reported[key] = 0;
			push(0, key);
		}
		return;
	}
	press(key);
	key_reported[key] = reported;
}

static void decode_sequence(void)
{
	char final = input_sequence[input_length - 1];
	input_sequence[input_length - 1] = '\0';
	char *parameters = input_sequence + 2;
	if (input_sequence[1] == '[' && *parameters == '?' && final == 'u') {
		char *end;
		unsigned long flags = strtoul(parameters + 1, &end, 10);
		if (end != parameters + 1 && *end == '\0')
			keyboard_events = (flags & 2) != 0;
		return;
	}
	if (*parameters == '?' || *parameters == '>' || *parameters == '<')
		return;
	int type = 1, reported = keyboard_events;
	char *modifiers = strchr(parameters, ';');
	unsigned long mods = 1;
	if (modifiers) {
		char *end;
		mods = strtoul(modifiers + 1, &end, 10);
		if (modifiers[1] < '0' || modifiers[1] > '9' || end == modifiers + 1 || mods == 0 || mods > 256)
			return;
		if (*end == ':') {
			char *event_end;
			long event = strtol(end + 1, &event_end, 10);
			if (event_end == end + 1 || (*event_end != '\0' && *event_end != ';') || event < 1 || event > 3)
				return;
			type = (int)event;
			reported = 1;
		} else if (*end != '\0' && *end != ';') {
			return;
		}
	}
	int key = -1, identity = -1;
	if (final >= 'A' && final <= 'D' && *parameters) {
		char *end;
		if (strtoul(parameters, &end, 10) != 1 || (*end != '\0' && *end != ';'))
			return;
	}
	switch (final) {
	case 'A': key = KEY_UPARROW; identity = 132; break;
	case 'B': key = KEY_DOWNARROW; identity = 133; break;
	case 'C': key = KEY_RIGHTARROW; identity = 134; break;
	case 'D': key = KEY_LEFTARROW; identity = 135; break;
	case 'u': {
		if (input_sequence[1] != '[' || *parameters < '0' || *parameters > '9')
			return;
		char *end;
		unsigned long code = strtoul(parameters, &end, 10);
		if (*end != '\0' && *end != ';')
			return;
		if (code < 128) {
			key = key_for_byte((unsigned char)code);
			identity = (int)code;
		}
		// Bare modifiers are available when all keys are reported.
		else if (code == 57441 || code == 57447) {
			key = KEY_RSHIFT;
			identity = code == 57441 ? 128 : 129;
		} else if (code == 57442 || code == 57448) {
			key = KEY_FIRE;
			identity = code == 57442 ? 130 : 131;
		}
		if (((mods - 1) & 4) && code >= 'a' && code <= 'z')
			key = KEY_FIRE;
		break;
	}
	default: return;
	}
	if (key >= 0)
		terminal_key((unsigned char)key, type, reported, identity);
}

static void read_input(void)
{
	unsigned char buffer[256];
	ssize_t n = read(STDIN_FILENO, buffer, sizeof(buffer));
	for (ssize_t i = 0; i < n; i++) {
		unsigned char c = buffer[i];
		if (input_length == 1 && c != '[' && c != 'O') {
			press(KEY_ESCAPE);
			input_length = 0;
		}
		if (c == 033) {
			input_sequence[0] = c;
			input_length = 1;
			escape_seen = DG_GetTicksMs();
			continue;
		}
		if (!input_length) {
			map_byte(c);
			continue;
		}
		if (input_length >= sizeof(input_sequence) - 1) {
			// Discard an oversized report through its final byte; its numeric
			// parameters must never become weapon presses or cheat characters.
			input_length = (c >= 0x40 && c <= 0x7e) ? 0 : sizeof(input_sequence);
			continue;
		}
		input_sequence[input_length++] = (char)c;
		if (input_length > 2 && c >= 0x40 && c <= 0x7e) {
			decode_sequence();
			input_length = 0;
		}
	}
	// A lone legacy Esc is ambiguous with a sequence prefix. Give split PTY
	// reads a short opportunity to complete; modern Esc is unambiguous CSI 27u.
	if (input_length == 1 && DG_GetTicksMs() - escape_seen >= 25) {
		press(KEY_ESCAPE);
		input_length = 0;
	}
}

// Only unreported holds expire. Real release events own modern-keyboard holds,
// so a long repeat delay cannot interrupt them and a tap stops on key-up.
static void expire_keys(void)
{
	uint32_t now = DG_GetTicksMs();
	for (int key = 0; key < 256; key++) {
		if (!key_down[key] || key_reported[key])
			continue;
		if (now - key_seen[key] < window_for((unsigned char)key))
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
	const char *hello = "\033[?25l\033[2J\033[>11u\033[?u";
	ssize_t ignored = write(STDOUT_FILENO, hello, strlen(hello));
	(void)ignored;
	int flags = fcntl(STDOUT_FILENO, F_GETFL);
	if (flags < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) < 0)
		die("cannot make frame output nonblocking");
	measure();
}

int main(int argc, char **argv)
{
	// Our own arguments are read before doomgeneric sees them; it ignores what
	// it does not know, so they are simply passed through.
	for (int i = 1; i < argc; i++) {
		// `-release <ms>`: how long a lone press holds a key down. Raise it above
		// your terminal's repeat delay if holding a direction still stutters; lower
		// it if a tap carries you too far. Once repeats are seen the window adapts
		// down from here on its own.
		if (strcmp(argv[i], "-release") == 0 && i + 1 < argc) {
			long ms = strtol(argv[i + 1], NULL, 10);
			if (ms >= MIN_RELEASE_MS && ms < 5000)
				hold_ms = (uint32_t)ms;
		}
	}

	doomgeneric_Create(argc, argv);
	for (;;)
		doomgeneric_Tick();
	return 0;
}
