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

## Rebuilding it

```bash
cd engine/src && make          # -> ./doom
```

Needs a C compiler and `make`; nothing else. Built here with
`cc (GCC) 16.2.1 20260810` and `-O2 -static`.

```text
sha256  eef61e89a62901c1d3642a38878ebc4ad9e0676eb3d4228651e494a2591423c2  bin/linux-x86_64/doom
sha256  81658aba7d8a4adf9f48771488200f633110d47471448451e3dfd2966ab72f4e  src/doomgeneric_thurbox.c
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
  synchronised output around each frame. Measured against a full-repaint port on
  the same WAD and terminal size: **~11 KB a frame instead of ~53 KB**, about
  0.7 MB/s instead of 3.7.
- **It synthesises key releases from timing.** thurbox cannot deliver them — its
  terminal layer never asks for `REPORT_EVENT_TYPES` and its loop matches on
  press — so a port that waits for a release latches every held key. Here a key is
  released once it has been quiet for `-release <ms>` (default 90), which is what
  auto-repeat provides while you hold it.
