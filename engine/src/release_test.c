// Drives the SHIPPED frontend's key timing against a fake clock.
//
// It compiles `doomgeneric_thurbox.c` itself rather than a copy of its logic, with
// `clock_gettime` redirected to a variable the test winds forward — so what is
// asserted is the code that runs, not a paraphrase of it.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static long fake_ms = 0;

static int test_clock_gettime(clockid_t id, struct timespec *ts)
{
	(void)id;
	ts->tv_sec = fake_ms / 1000;
	ts->tv_nsec = (fake_ms % 1000) * 1000000L;
	return 0;
}

#define clock_gettime test_clock_gettime
#define main frontend_main
#include "doomgeneric_thurbox.c"
#undef main

// Symbols the frontend names but this test never reaches.
pixel_t *DG_ScreenBuffer = NULL;
void doomgeneric_Create(int argc, char **argv)
{
	(void)argc;
	(void)argv;
}
void doomgeneric_Tick(void) {}

static int failures = 0;

static void check(int condition, const char *what)
{
	printf("%-60s %s\n", what, condition ? "ok" : "FAIL");
	if (!condition)
		failures++;
}

static void drained(unsigned char key, int *saw_down, int *saw_up)
{
	int pressed;
	unsigned char got;
	*saw_down = *saw_up = 0;
	while (DG_GetKey(&pressed, &got)) {
		if (got != key)
			continue;
		if (pressed)
			*saw_down = 1;
		else
			*saw_up = 1;
	}
}

static void reset(void)
{
	memset(key_seen, 0, sizeof(key_seen));
	memset(key_gap, 0, sizeof(key_gap));
	memset(key_down, 0, sizeof(key_down));
	queue_head = queue_tail = 0;
	fake_ms = 100000;
}

int main(void)
{
	int down, up;

	check(DEFAULT_RELEASE_MS == 700, "default window clears GNOME 500 / KDE 600 / X11 660");

	// --- a held key survives a stock repeat delay ----------------------------
	reset();
	hold_ms = DEFAULT_RELEASE_MS;
	map_byte('w');
	drained(KEY_UPARROW, &down, &up);
	check(down && !up, "hold: the first press goes down");

	fake_ms += 600; // KDE's repeat delay: the first repeat lands here
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(!up, "hold: still down at 600 ms, so a KDE-default delay is covered");
	map_byte('w'); // and the repeat keeps it down
	fake_ms += 40;
	map_byte('w');
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(!up, "hold: repeats take over from the initial window seamlessly");

	// --- once repeats flow, the window adapts down ---------------------------
	reset();
	map_byte('w');
	for (int i = 0; i < 6; i++) {
		fake_ms += 40;
		map_byte('w');
		expire_keys();
	}
	drained(KEY_UPARROW, &down, &up);
	check(!up, "repeats: a key repeating every 40 ms never releases");
	check(key_gap[KEY_UPARROW] == 40, "repeats: the interval is learned (40 ms)");
	check(window_for(KEY_UPARROW) == 100, "repeats: window collapses to 2x+20 = 100 ms");

	fake_ms += 99;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(!up, "repeats: 99 ms of silence is not a release");

	fake_ms += 2;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(up, "repeats: 101 ms of silence is — stopping is prompt");

	// --- a lone tap, before anything is known about the key ------------------
	reset();
	hold_ms = 300;
	map_byte('f');
	drained(KEY_FIRE, &down, &up);
	check(down, "tap: goes down");
	fake_ms += 299;
	expire_keys();
	drained(KEY_FIRE, &down, &up);
	check(!up, "tap: held for the full window");
	fake_ms += 2;
	expire_keys();
	drained(KEY_FIRE, &down, &up);
	check(up, "tap: released at 301 ms");

	// --- a tap AFTER the key's rate is known is short ------------------------
	reset();
	hold_ms = DEFAULT_RELEASE_MS;
	map_byte('w');
	for (int i = 0; i < 4; i++) {
		fake_ms += 40;
		map_byte('w');
	}
	fake_ms += 200;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(up, "learned: the held key released promptly");
	map_byte('w'); // a tap, now that the rate is known
	fake_ms += 101;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(up, "learned: a later TAP releases in ~100 ms, not 700 — the cost is one-off");

	// --- a slow double tap is not a repeat -----------------------------------
	reset();
	map_byte('w');
	fake_ms += 251;
	map_byte('w');
	check(key_gap[KEY_UPARROW] == 0, "slow taps: 251 ms apart is not auto-repeat");

	// --- keys are independent ------------------------------------------------
	reset();
	map_byte('w');
	fake_ms += 40;
	map_byte('w');
	map_byte('f');
	check(key_gap[KEY_UPARROW] == 40 && key_gap[KEY_FIRE] == 0,
	      "independence: learning one key teaches nothing about another");

	// --- -release still overrides ------------------------------------------
	reset();
	hold_ms = 900;
	map_byte('w');
	fake_ms += 899;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(!up, "-release 900: the initial window follows the flag");
	fake_ms += 2;
	expire_keys();
	drained(KEY_UPARROW, &down, &up);
	check(up, "-release 900: and still releases when the key is let go");
	hold_ms = DEFAULT_RELEASE_MS;

	printf("\n%s\n", failures ? "FAILURES" : "all timing checks passed");
	return failures ? 1 : 0;
}
