# thurbox-doom

Doom's engine, WADs, and settings for the **Doom tab** in
[thurbox-code-review](https://github.com/Thurbeen/thurbox-code-review). The agent
pane owns F5, the tab strip, and focus. It imports `lib/doom.lua` from this
package to render and control the program surface. The engine, WADs, and settings
remain here; the compatibility pane adds no visible focus stop.
Its action-band Doom entry invokes the agent pane's `doom.open` action, so it
also opens the tab instead of the old standalone pane. Without code-review
installed, the same file supplies the earlier standalone pane and F5 binding.

Install both repositories as cloned plugins:

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-code-review
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-doom
thurbox-cli plugin check
```

The code-review README explains how to replace the bundled agent pane. Installing
the Doom package puts its Linux x86_64 engine and WADs on disk but runs neither.
With a session selected, click **Doom** in the agent pane's strip or press **F5**.
F5 again returns to Agent. The selected tab is remembered per session.

Grant the **program** capability to `thurbox-code-review/plugins/20_agent.lua` from
`Ctrl+,` → `]` → the file → `t`. Until then, the Doom tab shows the exact command
it would run and the grant steps. Review's optional `run` capability is separate.
No settings file needs to be edited by hand.

The Doom settings remain on `thurbox-doom/plugins/40_doom.lua` in the Interface
settings tab. Existing `doom.program`, `doom.wad`, `doom.args`, and `doom.footer`
overrides continue to apply:

| Setting | Default | Purpose |
|---|---|---|
| `doom.program` | bundled Linux x86_64 engine | Relative paths resolve in the Doom clone; absolute paths are used as given. |
| `doom.wad` | `wad/doom1.wad` | The last program argument; `wad/freedoom1.wad` is also included. |
| `doom.args` | `-iwad` | Arguments before the WAD. |
| `doom.footer` | `true` | Show the controls row. |

On other platforms, the tab explains how to build an engine or configure
`doom.program`. `Ctrl+Alt+R` restarts the game; `Ctrl+Alt+X` stops it. The game
receives movement, firing, map, and menu keys while its surface is shown.

![DOOM in thurbox's standalone Doom pane, in the Doom theme](media/demo.gif)

The demo is the standalone pane, recorded in thurbox's built-in Doom theme: F5,
then E1M1 and its automap. With the agent pane the program surface and game
controls are the same; only the surrounding chrome differs.
`bash demo/record.sh` re-records it against the thurbox on `PATH`, from this
repository's committed state, in a throwaway home and tmux server.

## The engine

`engine/` is DOOM, built for this pane, **plus the complete source it was built
from** — which is what GPL-2.0 obliges anyone shipping a binary to provide.
`engine/README.md` carries the provenance, checksums and rebuild recipe; the short
version:

| | |
|---|---|
| binary | `engine/bin/linux-x86_64/doom`, 1.5 MB, statically linked — no runtime, no shared libraries |
| source | [doomgeneric](https://github.com/ozkl/doomgeneric) at `dcb7a8d`, unmodified, plus `doomgeneric_thurbox.c` |
| rebuild | `cd engine/src && make` — a C compiler and `make`, nothing else |
| licence | **GPL-2.0** (`engine/LICENSE`). The pane is MIT; the WAD is Freedoom's BSD |

Three things its frontend does deliberately, because a pane is not a terminal
emulator:

- **It paints cells.** One `▀` per character, top pixel in the foreground and bottom
  in the background at 24-bit colour — two vertical pixels per cell. A surface
  carries *characters*, so a port using a terminal graphics protocol (Kitty
  graphics, Sixel) would have nothing to be parsed into.
- **It diffs frames.** Only cells whose colour changed are emitted, in runs, inside
  synchronised-output markers. Writes are nonblocking: one unfinished frame is
  retained, and new frames are skipped until it finishes, so a slow reader cannot
  stop engine ticks or input polling. Measured against a full-repaint port on the same WAD
  and terminal size: **~11 KB a frame rather than ~53 KB**, about 0.7 MB/s rather
  than 3.7.
- **It synthesises key releases from timing**, which is what makes held keys usable
  here at all — see [Held keys](#held-keys-and-why-this-engine-handles-them).

You are not stuck with it: point `doom.program` at any DOOM that paints text cells
and reads its keys from stdin, and the pane frames that instead. A relative path
resolves inside this plugin's clone, so a build of your own at
`engine/bin/<os>-<arch>/doom` needs no setting at all.

## The WADs, both of which ship here

```text
wad/doom1.wad          DOOM shareware — "Knee-Deep in the Dead", the default
wad/freedoom1.wad      Freedoom: Phase 1 — the freely-licensed alternative
wad/NOTICE.md          what each is, its provenance and its terms
```

**`doom1.wad` is the default** because it is DOOM as people remember it. It is id
Software's shareware episode, unmodified: 4,196,020 bytes, md5
`f0cefca49926d00903cf57551d901abe` — the canonical v1.9 shareware WAD — extracted from
`doom19s.zip` in the idgames archive, id's own multi-volume installer. `DOOM1-README.txt`
is the README that came with it. Its terms are **id's**, not an open licence: the
shareware episode was released for free redistribution in unmodified form, which is what
this is.

**`freedoom1.wad` is there for anyone who would rather rely on a licence than a
permission.** Freedoom Phase 1, 0.13.0, sha256 `7323bcc1…f9e703d`, verified against
Freedoom's published `CHECKSUM` manifest, under a **modified BSD** licence whose terms
require `COPYING.txt` and `CREDITS.txt` to travel with it — which is why they are there
and must stay.

Switching is one setting:

```text
doom.wad = wad/freedoom1.wad
```

Or point it at any IWAD you own — `doom.wad`, `doom2.wad`, `plutonia.wad`. A commercial
WAD you bought is yours; shipping one would be somebody else's problem, which is why
neither is here.

### Held keys, the repeat delay, and the one number that matters

thurbox **cannot deliver key-release events** — a kernel limitation with two causes, both
confirmed upstream: the terminal layer asks for `DISAMBIGUATE_ESCAPE_CODES` and never
`REPORT_EVENT_TYPES`, and the event loop matches `KeyEventKind::Press`. It is recorded there
as **D12**. So "held" has to be inferred from auto-repeat, and that inference has a trap in
it worth understanding, because you will feel it before you read this.

Two different silences mean opposite things:

```text
repeat delay     500-660 ms   before the FIRST repeat  (GNOME 500, KDE 600, X11 660)
repeat interval    25-40 ms   between repeats after it
```

A release window shorter than the delay drops a held key half a second into every press —
move, stall, move — which reads as lag and is not. A window longer than the delay makes a
*tap* carry you for its whole length. One number cannot serve both, so the engine uses two:

- **before repeats begin on each hold**, the window is `-release` (default **700 ms**);
- **once repeats arrive**, their interval is measured and the window collapses to twice it
  (~100 ms), so letting go stops you promptly.

The interval is relearned on every hold. Reusing a previous hold's short interval caused
later holds to release before their first repeat. A lone tap can therefore remain down
for 700 ms; movement and use taps during that window may merge. Incoming presses
are also forwarded as keydown events, so menus and shortcuts respond to another
press without waiting for the inferred release. Adjacent duplicates buffered in
one input batch are coalesced; run-modifier repeats do not increment DOOM's shift
counter. Press-only input cannot distinguish a movement tap from a held key.
`-release` lets you choose this tradeoff; it does not add a delay before the first
press reaches the engine. True releases require host event
dispatch and input-transport changes, as well as terminal support.

`engine/src/release_test.c` checks timing with a fake clock (`cd engine/src && make test`).
`python3 tests/input_latency.py` runs the real engine in a separate pseudo-terminal and
records events at its input boundary. On Linux with a 100×40 terminal, the regression
measured a first movement press at 16 ms before the fix. With output reading paused,
fire was still unprocessed after 350 ms and arrived at 352 ms when reading resumed.
After the fixes, a later run delivered fire under the same stall in 9 ms, the
first movement press in 14 ms, and release after repeats in 97 ms. A subsequent
hold survived the full 600 ms initial repeat delay. Two Esc taps 150 ms apart
previously opened the menu but discarded the second press; they now open and close
it, with the second menu action measured at 9 ms. A synthetic 1024-byte repeat
backlog delivered a trailing Tab in 4 ms. The test also checks resumed output,
resize during a pending frame, and balanced run-modifier transitions.

The operator reported similar lag in thurbox and when running the bundled engine
standalone; both sessions used SSH. That comparison removes thurbox while retaining
SSH, terminal input, and engine handling. The controlled regression runs standalone
over a local PTY with a specified 600 ms repeat delay and 40 ms repeat interval;
it reproduces engine failures without SSH and does not measure the operator's
transport. The terminal application is unspecified. These are engine-side
measurements, excluding host dispatch, terminal/SSH latency and screen presentation.
DOOM simulates at 35 ticks per second; the reference host source
paces output paints at 33 ms and input paints at 16 ms. Frame presentation can lag even
when input is already reaching the engine. Startup screen wipes also run without normal
input polling. Neither terminal release support nor live gameplay was verified by this
test.

**If holding still feels wrong**, the honest fix is fewer milliseconds of guessing: shorten
your desktop's repeat delay, which helps every terminal program you use.

```bash
# KDE
kwriteconfig6 --file kcminputrc --group Keyboard --key RepeatDelay 200 && qdbus org.kde.KWin /KWin reconfigure
# GNOME
gsettings set org.gnome.desktop.peripherals.keyboard delay 200
# X11
xset r rate 200 30
```

With a 200 ms delay you can also drop `-release` to `250` in `doom.args` and stopping gets
sharper still. And if you point `program` at some other DOOM, ask whether it waits for real
releases: one that does will latch every key here, and no setting fixes that.

### Retracted: `tab` works

Earlier versions said `tab` was reserved by the kernel for focus, so DOOM's automap was
unreachable. That was wrong. The reserved set is `ctrl+q`, `f10`, `ctrl+h`, `ctrl+l`
and `f12`; `tab` is forwarded to the focused pane on purpose, because every coding
agent needs it for completion. **The automap works.** The kernel's own `F1` help and
`docs/PLUGINS.md` claimed otherwise; both were fixed upstream — in the commit "stop
claiming tab moves focus, because it does not" — after this plugin reported it.

## What this deliberately is not

A Lua software renderer. It is *expressible* — `surface` takes Lua-supplied styled runs
and `parse_color` accepts `#rrggbb` — but there is no way to get frames into Lua: no
WASM runtime, no ffi, no filesystem, and `run` completes rather than streams. A frame
drawn cell by cell is thousands of styled runs against a conversion path whose hottest
measured case is ~100 spans a pane (`docs/V2-KERNEL.md`). A program pane costs none of
it: the cells never pass through Lua.

The Linux engine binary ships beside its corresponding GPL source. Build output
belongs outside the watched interface directory; copy only the finished binary
into an isolated plugin copy when testing another build.

## Credits

- **id Software**, for DOOM, and for releasing its source.
- **[doomgeneric](https://github.com/ozkl/doomgeneric)** by ozkl, the portable split
  that makes a frontend this small possible: six functions and a framebuffer.
- **[Freedoom](https://freedoom.github.io/)**, for game data anyone may ship.

## Licences

This plugin is MIT (see [`LICENSE`](LICENSE)) — Copyright (c) 2026 Thurbeen, matching
`Thurbeen/thurbox`.

**`engine/` is GPL-2.0**, not MIT: it is DOOM's source and a binary built from it.
`engine/LICENSE` is the licence, and `engine/src/` is the corresponding source that
shipping a GPL binary obliges — the exact tree the committed binary was compiled from,
rather than a link to a repository that may move.

**The WADs are game data and neither is MIT.** `wad/NOTICE.md` is the full statement;
briefly: `doom1.wad` is id Software's shareware episode, redistributed unmodified under
id's terms rather than an open licence, and `freedoom1.wad` is under Freedoom's
**modified BSD**, whose conditions require `wad/COPYING.txt` and `wad/CREDITS.txt` to
accompany it — removing them would break them.

So: MIT for the pane, GPL-2.0 for the engine, and for the data one open licence and one
permission. A commercial WAD you supply yourself is your own affair.

## Checks

`bash scripts/check.sh` runs Lua formatting, engine timing and PTY input tests,
the media check, and isolated plugin loading.
The agent-pane integration is exercised by `tests/run.sh --render` in
thurbox-code-review and by `thurbox-cli plugin check` after installing both plugins.
`tests/demo_media.sh` checks that the committed demo keeps gameplay in every frame.
