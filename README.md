# thurbox-doom

Doom's engine, WADs, and settings for the **Doom tab** in
[thurbox-code-review](https://github.com/Thurbeen/thurbox-code-review). The agent
pane owns F5, the tab strip, and focus. It imports `lib/doom.lua` from this
package to render and control the program surface. The engine, WADs, and settings
remain here; the compatibility pane adds no visible focus stop.

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

The [demo](media/demo.gif) shows the earlier standalone pane. The program surface
and game controls remain the same; the surrounding chrome is now the agent pane.

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
  synchronised-output markers. Measured against a full-repaint port on the same WAD
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

- **before any repeat is seen for a key**, the window is `-release` (default **700 ms**,
  which clears every common delay above);
- **once repeats arrive**, their interval is measured and the window collapses to twice it
  (~100 ms), so letting go stops you promptly.

The cost is one long first tap per key per session — after that the rate is known and taps
release in ~100 ms too. `engine/src/release_test.c` asserts all of it against a fake clock
(`cd engine/src && make test`), including the case that made this necessary: a 600 ms delay
under a 300 ms window releases the key at 301 ms.

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

`bash scripts/check.sh` runs Lua formatting, engine tests, and the media check.
The agent-pane integration is exercised by `tests/run.sh --render` in
thurbox-code-review and by `thurbox-cli plugin check` after installing both plugins.
The existing demo records the earlier standalone pane and is retained as gameplay
reference.
