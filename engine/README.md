# The engine

DOOM itself, built for a thurbox program pane, plus the complete source it was
built from. **This directory is GPL-2.0** (see `LICENSE` beside this file); the
pane in `plugins/` is MIT and the WAD in `wad/` is Freedoom's modified BSD. Three
licences, three directories, no ambiguity about which covers what.

## What is here

| Path | What |
|---|---|
| `bin/linux-x86_64/doom` | a statically linked binary, 1.5M, no shared libraries and no runtime |
| `src/doomgeneric_thurbox.c` | the frontend written for this pane |
| `src/` (the rest) | [doomgeneric](https://github.com/ozkl/doomgeneric) at commit `dcb7a8d`, with one marked change (below) |
| `src/Makefile` | the recipe that produced the binary |
| `LICENSE` | GNU GPL v2, which DOOM's source carries |

Shipping a binary under the GPL obliges the distributor to ship its corresponding
source. That is what `src/` is: not a pointer to a repository that may move, but
the exact tree this binary was compiled from.

## The one change to the vendored source

`i_system.c`'s `ZenityAvailable()` returns 0, marked `THURBOX MODIFICATION` in place.
Upstream probes for `/usr/bin/zenity` and opens a **GUI error box** when DOOM fails —
which inside a terminal pane is a dialog nobody can see, announced by GTK warnings
printed over the game. `I_Error`'s message still goes to stderr, where the pane shows
it. Everything else in `src/` is upstream's, byte for byte.

## Testing the key timing

```bash
cd engine/src && make test
```

Compiles `doomgeneric_thurbox.c` itself against a fake clock and asserts the release
behaviour — that a held key survives a stock repeat delay, that the window collapses once
the repeat rate is known, that a tap does not stick, and that `-release` still overrides.
The timing test needs no doomgeneric objects. From the repository root,
`python3 tests/input_latency.py` builds and runs the real engine in an isolated PTY,
checking input and simulation ticks during output backpressure, tap-turn angle,
real press/repeat/release events, held-turn continuity, frame cadence, split reads,
aliases, terminal-mode restoration, and resumed rendering after resize.
`python3 tests/ghostty_input.py` is the optional physical-key comparison under an
isolated Ghostty/Xvfb display; it also records `media/input-turning.gif`. This optional
Linux test needs Ghostty, Xvfb, X11/XTest libraries and ffmpeg. Both tests need
Python 3 and remove their temporary directories on exit; comparison clips remain
in the ignored engine build directory.

## Rebuilding it

```bash
cd engine/src && make          # -> ./doom
```

Needs a C compiler and `make`; nothing else. Built here with
`cc (GCC) 16.2.1 20260810` and `-O2 -static`.

```text
sha256  eef0ea3eeeff551be3925f78a45fb3cae268fd7b2f3e9cfcf750c002c3669d09  bin/linux-x86_64/doom
sha256  c02916d1219a6d2b08cb3f35f69c4150f8abd57f9fcdd91dd5728c4face5d49f  src/doomgeneric_thurbox.c
```

A rebuild will not match that hash byte for byte — a different compiler version or
path lays out the binary differently — which is why the source is here to check
rather than a promise of reproducibility.

## Another platform

Only `linux-x86_64` is committed, because it is the only target that could be
built and *run* where this was written. The pane reads `thurbox.platform` and
looks for `engine/bin/<os>-<arch>/doom`, so building for your own machine and
dropping it there needs no configuration:

```bash
cd engine/src && make && mkdir -p ../bin/macos-aarch64 && cp doom ../bin/macos-aarch64/
```

Or point the `doom.program` setting anywhere you like — the pane frames whatever
paints text cells and reads keys from stdin.

## What the frontend does differently

Three things worth knowing, all in `src/doomgeneric_thurbox.c`:

- **It paints cells.** One `▀` per character, top pixel in the foreground and
  bottom in the background, 24-bit colour: two vertical pixels per cell. A
  surface carries characters, so a terminal graphics protocol would have nothing
  to be parsed into.
- **It diffs frames.** Only cells whose colours changed are emitted, in runs, with
  synchronised output around each frame. Output is nonblocking; an unfinished
  frame is retained before another is built, so backpressure skips paints rather
  than blocking game ticks. Measured against a full-repaint port on
  the same WAD and terminal size: **~11 KB a frame instead of ~53 KB**, about
  0.7 MB/s instead of 3.7.
- **It requests real key releases** with Kitty keyboard flags 11, and keeps a
  reported key down until its release, independent of repeat delay. A press-only
  host must be changed to forward those events. Timing inference is retained only
  for a legacy byte stream; its 700 ms initial timeout can turn a lone arrow tap
  through 79.1° and cannot distinguish that tap from a hold.
