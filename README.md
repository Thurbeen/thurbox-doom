# thurbox-doom

DOOM in a thurbox pane. The plugin is one Lua file: it asks the kernel for a
program pane, frames it, and owns the key rules. The kernel runs the program in a
real terminal, resizes it to the rect and parses its output into cells — the
plugin never sees a frame.

A freely-redistributable WAD ships alongside it, so the only thing left to
install is a terminal DOOM.

---

## Read this before anything else

**This needs thurbox's v2 plugin kernel, which is not released.** It lives on
branch `thurbox-v2-ui-approach`, open as
**[PR #936](https://github.com/Thurbeen/thurbox/pull/936)** in
`Thurbeen/thurbox`. `main` has no `ui/` directory and no plugin API, so on a
released thurbox this file is inert.

More specifically, it needs the **program-pane capability**, which landed on that
branch in *"feat(ui): let a plugin run an interactive program in a pane it owns"*.
On a build older than that commit this plugin loads, declares a capability the
kernel does not know, and draws its untrusted panel forever.

On that branch the kernel **is** the interface, so it runs as plain **`thurbox`**.
There is no `thurbox2` binary.

**The plugin API is explicitly unstable** (see the banner atop `docs/PLUGINS.md`),
and **plugins are trusted code** — this one asks for a capability that holds a
process open on your keystrokes. Read it before you install it: 366 lines, 110 of
them comments.

## What it does

- **Not trusted yet** → a panel saying what it would run, the exact command line,
  and how to grant the capability. That is the state every user sees first.
- **Trusted** → it asks for its pane on every frame and frames the surface, with a
  controls row underneath.
- **Released** (`ctrl+alt+x`) → the program is stopped and the pane given up, with
  the chord that starts it again.

No session is involved. The pane belongs to the plugin, so there is one DOOM
whatever session is selected — and none is required. **Nothing is persisted**:
the kernel re-finds the pane by its window name, so there is no id to remember and
none to go stale, and a reload (`F10`) leaves the game running.

### There is no `agents.toml` entry any more

The first version of this plugin had no way to start a process, so it created a
*session* whose agent was a `doom` entry in `agents.toml` — a game pretending to
be a coding agent to borrow the one field of the session model that spawns a pty.
That is gone. The program, its arguments and the WAD path are now **settings on
this plugin**, and the kernel starts the process itself.

## Prerequisites

### A terminal DOOM that paints text cells

That constraint is the whole story: a thurbox `surface` carries **cells**, so the
port has to draw with ordinary text and SGR colour. A port that paints images via
the Kitty graphics protocol has nothing to be parsed into — which rules out
[`cryptocode/terminal-doom`](https://github.com/cryptocode/terminal-doom),
whose README describes exactly that. I did not test it; I do not expect it to
render here.

**[`badlogic/pi-doom`](https://github.com/badlogic/pi-doom)** is what this is
documented against, and what I tested. GPL-2.0, TypeScript, DOOM compiled to
WebAssembly from [doomgeneric](https://github.com/ozkl/doomgeneric). Frames are
**half-block characters (`▀`) with 24-bit colour** — the top pixel in the
foreground, the bottom in the background — which is exactly what a cell surface
can carry.

```bash
git clone https://github.com/badlogic/pi-doom ~/src/pi-doom
cd ~/src/pi-doom
npm install
npm install --no-save tsx        # see the note below
```

What I verified on this machine (node v26.7.0, pi-doom at `8257577`):

- It runs, and it accepted **our vendored Freedoom WAD**: it logs
  `DOOM initialized (640x400)` and plays.
- Its output is genuinely cells. In one capture: **152,800 `▀` glyphs with 152,800
  paired `ESC[38;2;…m` / `ESC[48;2;…m` truecolor runs, and zero Kitty-graphics or
  Sixel sequences.**
- It runs **from any working directory** when given absolute paths, which is what
  the pane needs: a program pane has no session and therefore no repository, so
  the kernel runs it in the interface directory.
- Throughput: ~17 MB over a 25 s capture, ~10 frames a second at 80×24, ~69 KB a
  frame. Its engine loop targets 35 fps (`setInterval(…, 1000/35)`), so the
  terminal size and JS overhead are what you are actually bound by.

**The `tsx` note.** `npm start` runs `npx tsx`, and on a machine without `tsx`
that **prompts** to install it — which in a pane would sit there waiting for a `y`
you cannot see. Install it once, as above, and point the plugin at the binary
directly.

Other ports may work. The requirement is text plus SGR colour on stdout, and keys
read from stdin.

### A WAD — included

```text
wad/freedoom1.wad        Freedoom: Phase 1, 0.13.0 — the single-player campaign
wad/COPYING.txt          Freedoom's licence, reproduced as its terms require
wad/CREDITS.txt          the contributor list COPYING.txt refers to
wad/CREDITS-MUSIC.txt    the music credits
```

[Freedoom](https://freedoom.github.io/)
([`freedoom/freedoom`](https://github.com/freedoom/freedoom)) is free game data
under a **modified BSD licence** permitting binary redistribution as long as the
notice, conditions and disclaimer travel with it — which is what
`wad/COPYING.txt` is doing there. Phase 1 rather than FreeDM because FreeDM's maps
are deathmatch arenas with no monster placement.

Provenance: extracted from `freedoom-0.13.0.zip`, whose SHA256 matched Freedoom's
own published `freedoom-0.13.0-CHECKSUM` manifest. The shipped file is

```text
sha256  7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d  freedoom1.wad
```

pi-doom bundles a shareware `doom1.wad` of its own and falls back to it when you
name no WAD. Pointing the `wad` setting at the Freedoom file above is the
freely-distributable route, and it is the combination I tested. A shareware or
commercial WAD is your own affair; **no port and no binary is vendored here.**

## Install

The v2 branch has a pane package manager, and this repository is a package:
`plugin.toml` at its root names the pane and where it lands.

```bash
git clone https://github.com/Thurbeen/thurbox-doom ~/src/thurbox-doom
thurbox-cli plugin install ~/src/thurbox-doom
```

Or from GitHub's raw host, no clone — the manager fetches `plugin.toml` and then
the pane from that base:

```bash
thurbox-cli plugin install https://raw.githubusercontent.com/Thurbeen/thurbox-doom/main
```

**The `main` URL works only once this is on `main`.** While it sat on a branch I
measured `…/main/plugin.toml` as a 404 and both `…/<branch>/plugin.toml` and
`…/<commit-sha>/plugin.toml` as 200 — so on a 404, put a branch name or a sha
where `main` is.

> **`thurbox-cli plugin install doom` does *not* install this.** A bare name
> resolves to `ui-plugins/<name>` inside the thurbox repository at your binary's
> release tag, and that repository now ships a `doom` pane of its own as the
> worked example for the capability. It is a different, smaller plugin in its own
> slot. Install this one by URL or path.

Either way the pane lands at `plugins/40_doom.lua` in your interface directory and
the entry is recorded in `plugins.toml` beside it:

```toml
[[plugin]]
src  = "https://raw.githubusercontent.com/Thurbeen/thurbox-doom/main"
file = "plugins/40_doom.lua"
```

`--as plugins/NN_doom.lua` puts it elsewhere — the number is load order. After
hand-editing the spec, `thurbox-cli plugin sync` converges the directory and its
exit status says whether it worked; `plugins.lock` records what each entry resolved
to and the digest of every file delivered. An edit you make to an installed file is
kept, and deleting one is remembered.

Two more things worth knowing:

- **The WAD is not installed by any of this.** A package may deliver **Lua only** —
  every declared destination must end in `.lua` — so `plugin install` brings
  `doom.lua` and nothing else. Keep the clone, or move `wad/freedoom1.wad`
  somewhere of your own, and name it in the `wad` setting.
- **A pin only means something for a bare name.** `src` here is a URL, so `pin` is
  recorded and otherwise ignored; put the ref in the URL.

By hand still works — the manager is a convenience, not a gate:

```bash
cp doom.lua ~/.config/thurbox/ui/plugins/40_doom.lua
```

`~/.config/thurbox/ui/` is the interface directory, watched, so the pane appears on
save (120 ms debounce); `F10` forces a reload. `THURBOX_UI_DIR` overrides that
path, and a **dev build** (`0.0.0-dev`) reads `~/.config/thurbox-dev/ui` instead.

The pane declares `slot = "center"`, which the stock `layout.lua` always places, so
**there is no arrangement edit to make** and `thurbox-cli plugin check` — which now
fails a pane whose slot nothing places — has nothing to complain about. The cost is
that DOOM and the agent take turns in the centre rather than sitting side by side.
If you would rather have both, give this pane a slot of its own and place it: a
two-line edit to `layout.lua`, which nothing here writes for you.

## Trust it

The pane will draw its untrusted panel until you grant the capability:

```text
settings (ctrl+, or F6) → ] to the Interface tab → select the file → t
```

`program` is a **different grant from `run`**, deliberately. `run` is bounded on
every axis that matters — capped output, a timeout, four at a time — and an
interactive program has none of those and holds your keyboard as well. Trusting a
pane to poll `top` is not the same decision as letting it hold a process open on
your keystrokes, so the kernel asks separately, per file, revocably. The Interface
tab says which of the two a file wants.

Installing grants nothing. Nothing starts until you say `t`.

## Settings

Declared as data, so they appear in the settings modal and are stored in
`~/.config/thurbox/ui.json`. These are what replaced the `agents.toml` entry.

| Setting | Default | What it does |
|---|---|---|
| `doom.program` | `pi-doom` | the program to run in the pane |
| `doom.wad` | *(empty)* | WAD path, passed as the **last** argument |
| `doom.args` | *(empty)* | extra arguments, split on spaces |
| `doom.footer` | `true` | draw the controls row (it costs the game one row) |

Two ways to point it at pi-doom. Either write a wrapper somewhere on `PATH`:

```bash
#!/bin/sh
# ~/.local/bin/pi-doom
exec ~/src/pi-doom/node_modules/.bin/tsx ~/src/pi-doom/src/standalone.ts "$@"
```

…and leave `doom.program` at its default, or skip the wrapper and set:

| Setting | Value |
|---|---|
| `doom.program` | `/home/you/src/pi-doom/node_modules/.bin/tsx` |
| `doom.args` | `/home/you/src/pi-doom/src/standalone.ts` |
| `doom.wad` | `/home/you/src/thurbox-doom/wad/freedoom1.wad` |

**Absolute paths.** A program pane has no session and therefore no repository, so
the kernel runs it locally in the interface directory — a relative path resolves
against `~/.config/thurbox/ui/`, which is not what you meant.

**Why `wad` is separate from `args`.** Arguments are passed as a list and quoted
individually, so a WAD path containing a space survives as one argument. `args` is
split on whitespace for flags; the path that must not be split has its own field.

## Controls

Everything the plugin does not claim goes to the program, because it declares
`input = "session"`.

| Action | Keys |
|---|---|
| move | `w` `a` `s` `d` or `↑` `↓` `←` `→` |
| run | `shift` + `wasd` |
| fire | `f`, or any `ctrl` chord |
| use / open | `space` |
| weapons | `1`–`7` |
| menu | `esc` |
| quit the game | `q` |

Those are pi-doom's, read from its key map. `q` quits **the game**, not the pane:
the kernel then reports the program as exited rather than drawing a frozen grid,
and `ctrl+alt+r` starts it afresh.

| Chord | Does |
|---|---|
| `ctrl+alt+r` | restart DOOM in this pane |
| `ctrl+alt+x` | stop it and give up the pane |

Both are plugin-scoped, so they fire only while this pane has focus, and both are
rebindable (`~/.config/thurbox/ui.json`, via the interface's help and Interface
tab). They are `ctrl+alt+` chords because a declared chord is consumed before the
surface ever sees it, and DOOM wants every bare key there is — the letters
included, for cheats.

### Two caveats that would otherwise read as bugs

**1. `tab` cannot reach DOOM.** `ctrl+q`, `f10`, `tab` / `shift+tab`,
`ctrl+h` / `ctrl+l` and `f12` are reserved by the kernel, which is what stops a
program that eats every key from trapping you in it. **`tab` is DOOM's automap**,
so the automap does not arrive. Rebinding is where you would look — chord overrides
live in `ui.json` — but `docs/PLUGINS.md` says the reserved chords "cannot be
rebound **or** consumed", so it is not clear moving focus off `tab` is even
offered. I could not try it.

**2. Key releases, and why this port cares more than most.** pi-doom asks the
terminal for press/release events: its component sets `wantsKeyRelease = true`, and
pi-tui writes the Kitty keyboard sequence `ESC[>3u` (flags 1|2 — disambiguate, plus
**report event types**) once a terminal answers its capability query. It then
pushes a DOOM key down on a press and up on a release.

The consequence is the part to watch: **it releases only on an explicit release
event.** In my capture under a plain pty, no `ESC[>3u` was written at all — the
query went unanswered, so it fell back to presses only. If the same happens inside
the pane, a direction key may latch and you will keep walking. I could **not** test
this in the pane. It is the first thing to try, and if movement sticks, this is
why. The setting worth reaching for is `set -g extended-keys on` in `~/.tmux.conf`,
though on the tmux I checked (3.7b) the manual documents that as `modifyOtherKeys`
for *modified* keys and mentions neither the Kitty protocol nor release events.

## What this deliberately is not

A Lua software renderer. It is *expressible* — `surface` takes Lua-supplied styled
runs and the kernel's `parse_color` accepts `#rrggbb` — but there is no way to get
frames into Lua: no WASM runtime, no ffi, no filesystem, and `run` completes rather
than streams.

The arithmetic is against it too. A renderer emitting one styled run per cell
spends thousands a frame, against a conversion path whose hottest measured case is
~100 spans a pane (`docs/V2-KERNEL.md`). A program pane costs none of it: the cells
never pass through Lua at all.

## Credits

- **id Software**, for DOOM.
- **[`badlogic/pi-doom`](https://github.com/badlogic/pi-doom)** by Mario Zechner —
  the port this is documented against, and the prior art for the whole idea: DOOM
  inside a terminal agent's UI. It runs the game **in-process as WASM** and paints
  half-blocks itself. thurbox cannot do that from Lua — no WASM runtime, no
  filesystem, no clock of its own, and a plugin never sees a frame — so here the
  same binary runs as the pane's own process and the kernel does the parsing.
- **[doomgeneric](https://github.com/ozkl/doomgeneric)**, underneath it.
- **[Freedoom](https://freedoom.github.io/)**, for a WAD anyone may ship.

## Licences

This plugin is MIT (see [`LICENSE`](LICENSE)) — Copyright (c) 2026 Thurbeen,
matching `Thurbeen/thurbox`.

The rest is not. **DOOM, the ports and the WADs carry their own licences.**

- **`wad/freedoom1.wad` ships here** under Freedoom's **modified BSD** licence,
  which requires the notice, conditions and disclaimer to accompany it:
  `wad/COPYING.txt` and `wad/CREDITS.txt` are that accompaniment, and removing them
  would break the terms. The root `LICENSE` does not cover the WAD.
- **No port and no binary is vendored.** pi-doom is **GPL-2.0**, as are other
  doomgeneric-derived ports; you clone and build it yourself, under its own licence.
  Shipping a GPL binary here would oblige this repository to carry its
  corresponding source, which is a deliberate non-goal.
- A shareware or commercial WAD is yours to obtain and abide by. None is here.

## Status

Written against branch `thurbox-v2-ui-approach` at `953e177`, reading
`docs/PLUGINS.md`, `src/kernel/command.rs`, `src/kernel/convert.rs`,
`src/kernel/terminal.rs`, `src/kernel/host.rs` and `thurbox.yml` for the
program-pane contract.

Checked with `luac -p`, `selene` against **that commit's** `thurbox.yml` (the
sandbox definition, which is where `thurbox.granted` is declared — an older copy
rejects this file), and `stylua` with the pinned `.stylua.toml`. It also runs under
a stub harness: kernel globals faked, `lib/theme.lua`, `lib/widgets.lua` and
`lib/settings.lua` the real files, exercising the untrusted, running and released
states, the every-frame ask, argument assembly (including a WAD path with a space
staying one argument), the error path, both chords, and every emitted node against
the fields `convert.rs` accepts.

**I have never seen this pane render.** The interface cannot be launched from where
this was written, so no visual claim here comes from a screen. What *is* measured is
the port, outside thurbox: that it runs, that it accepts the shipped WAD, and that
it emits cells rather than graphics-protocol images. Untested: the pane itself,
key releases through the kernel and tmux, and every `thurbox-cli plugin` command —
the installed CLI is `0.0.0-dev` and has no `plugin` subcommand.
