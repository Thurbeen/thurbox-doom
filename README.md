# thurbox-doom

DOOM in a thurbox pane. The plugin is one Lua file: it asks the kernel for a
program pane, frames it, and owns the key rules. The kernel runs the program in a
real terminal, resizes it to the rect and parses its output into cells — the
plugin never sees a frame.

Everything it needs ships with it. `thurbox-cli plugin install git+…` clones this
repository into your interface directory, which brings the launcher and a
freely-redistributable WAD along with the pane — so there is nothing to configure
and nothing to fetch by hand:

```text
<interface dir>/thurbox-doom/plugins/40_doom.lua   the pane
<interface dir>/thurbox-doom/bin/doom              the launcher, executable
<interface dir>/thurbox-doom/wad/freedoom1.wad     the WAD
```

Grant it the `program` capability and press nothing: it starts.

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
process open on your keystrokes. Read it before you install it: 464 lines, 147 of
them comments — and `bin/doom`, which is 60 lines of shell.

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

## What it runs

The pane frames whatever program you point it at, and the constraint is the whole
story: a thurbox `surface` carries **cells**, so the program has to paint with
ordinary text and SGR colour. A port that paints images via the Kitty graphics
protocol has nothing to be parsed into — which rules out
[`cryptocode/terminal-doom`](https://github.com/cryptocode/terminal-doom), whose
README describes exactly that. I did not test it; I do not expect it to render here.

`bin/doom`, which ships here and is what the pane runs by default, finds an engine
in three steps:

1. `$THURBOX_DOOM_PROGRAM`, if you set it — yours wins;
2. `pi-doom` on `PATH`, if you already have one;
3. otherwise it fetches **[`badlogic/pi-doom`](https://github.com/badlogic/pi-doom)**
   once into `${XDG_CACHE_HOME:-~/.cache}/thurbox-doom/` and runs that.

pi-doom is GPL-2.0, TypeScript, DOOM compiled to WebAssembly from
[doomgeneric](https://github.com/ozkl/doomgeneric), and it paints **half-block
characters (`▀`) with 24-bit colour** — the top pixel in the foreground, the bottom
in the background. That is what a cell surface can carry.

Step 3 needs `git`, `node` and `npm`; without them the launcher says which are
missing and how to point it elsewhere. **Nothing runs at install time** — the
launcher runs when the pane runs, under the capability you granted, in a pane where
you can watch it and kill it.

What I verified by running it, from an empty cache and with no arguments: it cloned
pi-doom, installed its dependencies, found the shipped WAD by itself, logged
`DOOM initialized (640x400)`, and emitted **1,677,680 `▀` glyphs with 1,677,680
paired truecolor runs and zero Kitty-graphics or Sixel sequences.** Roughly 10
frames a second at 80×24, against an engine loop targeting 35.

**Why the cache is outside the interface directory.** That directory is watched
recursively, and an `npm install` under it would fire thousands of events — and the
counter-intuitive failure is not "reloads too often" but "stops reloading at all",
because a burst keeps the debounce window rolling forward. Keeping the working copy
clean matters for a second reason: a dirty tree is what makes `plugin update` report
`kept` and refuse to move, so build output inside the clone would block your own
updates.

### The WAD, which also ships here

```text
wad/freedoom1.wad        Freedoom: Phase 1, 0.13.0 — the single-player campaign
wad/COPYING.txt          Freedoom's licence, reproduced as its terms require
wad/CREDITS.txt          the contributor list COPYING.txt refers to
wad/CREDITS-MUSIC.txt    the music credits
```

[Freedoom](https://freedoom.github.io/)
([`freedoom/freedoom`](https://github.com/freedoom/freedoom)) is free game data under
a **modified BSD licence** permitting binary redistribution as long as the notice,
conditions and disclaimer travel with it — which is what `wad/COPYING.txt` is doing
there. Phase 1 rather than FreeDM because FreeDM's maps are deathmatch arenas with no
monster placement.

Provenance: extracted from `freedoom-0.13.0.zip`, whose SHA256 matched Freedoom's own
published `freedoom-0.13.0-CHECKSUM` manifest. The shipped file is

```text
sha256  7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d  freedoom1.wad
```

A shareware or commercial WAD is your own affair, and **no engine binary is vendored
here** — the launcher fetches one, under its own licence.

## Install

This plugin carries a payload, so it is installed by **cloning** it:

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-doom
```

A `git+` prefix, a `.git` suffix or `git@host:path` are the three forms that clone.
A bare `https://…` deliberately does *not* — that spelling means "fetch the files
this manifest names from this base", and that path is text-only, so it could not
carry the WAD or the launcher anyway.

The working copy lands at `<interface dir>/thurbox-doom/` and **keeps its `.git`**,
which is what makes `thurbox-cli plugin update` a fetch rather than a re-download and
what protects your edits: git will not move a dirty working tree, so a `sync` over a
pane you changed reports `kept`, and `git diff` shows what you did. `install` finds
the pane itself — the single `.lua` under `plugins/` — and records it:

```toml
[[plugin]]
src  = "git+https://github.com/Thurbeen/thurbox-doom"
file = "thurbox-doom/plugins/40_doom.lua"
```

The lock records the **commit**, not the branch, so the same spec and lock reproduce
the same bytes elsewhere. Load order still comes from the `40_` prefix.

> **`thurbox-cli plugin install doom` does not install this.** A bare name resolves
> into the thurbox repository's own examples, where there is a smaller `doom` pane
> demonstrating the capability. This one installs by repository.

**What cloning means, plainly:** it puts this repository's files on your disk,
executable bits included — `bin/doom` arrives executable. Nothing is executed by
installing, and the launcher cannot run until you grant the `program` capability
below. Treat a repository you did not write the way you would treat one you were
about to `make` in; this one is three files and a WAD, and reading `bin/doom` takes a
minute.

`~/.config/thurbox/ui/` is the interface directory, watched, so the pane appears on
save (120 ms debounce); `F10` forces a reload. `THURBOX_UI_DIR` overrides the path,
and a dev build (`0.0.0-dev`) reads `~/.config/thurbox-dev/ui` instead.

The pane declares `slot = "center"`, which the stock `layout.lua` always places, so
**there is no arrangement edit to make** and `thurbox-cli plugin check` — which fails
a pane whose slot nothing places — has nothing to complain about. The cost is that
DOOM and the agent take turns in the centre; give the pane a slot of its own if you
would rather have both.

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
| `doom.program` | *(empty)* | program to run. Empty means `<interface dir>/thurbox-doom/bin/doom` — the launcher this repository ships — and `pi-doom` from `PATH` if the kernel publishes no interface directory |
| `doom.wad` | *(empty)* | WAD, passed as the **last** argument. Empty means `<interface dir>/thurbox-doom/wad/freedoom1.wad`, and no WAD argument at all if there is no interface directory to look in |
| `doom.args` | *(empty)* | extra arguments, split on spaces |
| `doom.footer` | `true` | draw the controls row (it costs the game one row) |

Empty is not "unset" here, it is "the copy that came with the package". Nothing is
invented: with no interface directory published, the WAD argument is omitted rather
than pointed at a path that does not exist, and every port worth running looks for
a WAD of its own.

To run a port from somewhere else, set them. Skipping the wrapper entirely:

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
| automap | `tab` |
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

### One caveat, and one retraction

**Retracted: `tab` works.** Earlier versions of this README said `tab` was reserved
by the kernel for focus and that DOOM's automap was therefore unreachable. That was
wrong. The reserved set is `ctrl+q`, `f10`, `ctrl+h`, `ctrl+l` and `f12`; `tab` is
forwarded to the focused pane on purpose, because every coding agent needs it for
completion. **The automap works**, and the controls row advertises it. The kernel's
own `F1` help and `docs/PLUGINS.md` claimed otherwise; both were fixed upstream after
this plugin reported it.

**Key releases, and why this port cares more than most.** pi-doom asks the terminal
for press/release events: its component sets `wantsKeyRelease = true`, and pi-tui
writes the Kitty keyboard sequence `ESC[>3u` (flags 1|2 — disambiguate, plus **report
event types**) once a terminal answers its capability query. It then pushes a DOOM key
down on a press and up on a release.

The consequence is the part to watch: **it releases only on an explicit release
event.** In my capture under a plain pty no `ESC[>3u` was written at all — the query
went unanswered, so it fell back to presses only. If the same happens inside the pane,
a direction key may latch and you will keep walking. I could **not** test this in the
pane; it is the first thing to try, and if movement sticks, this is why. The setting
worth reaching for is `set -g extended-keys on` in `~/.tmux.conf`, though on the tmux I
checked (3.7b) the manual documents that as `modifyOtherKeys` for *modified* keys and
mentions neither the Kitty protocol nor release events.

## How the payload gets there

Worth a paragraph, because it changed and the old answer is in this repository's
history. Until recently a package could deliver **Lua only**: the file-by-file path
returns a `String` and decodes remote output lossily, so a WAD or an executable was
not refused, it was silently corrupted — and `validate_destination`'s `.lua` rule was
the only thing standing between a user and that. This README used to carry a section
explaining what the installer would need to grow.

The answer upstream was not to plumb bytes through that seam: a plugin with a payload
is a **repository**, and `git clone` already provides arbitrary bytes, whatever layout
the author chose, an exact identity for what was delivered, and a refusal to clobber a
dirty tree. So there is no checksum to maintain here — the commit in the lock
identifies every byte — no executable bit to declare, and no platform matrix in the
manifest. Platform selection is `thurbox.platform`, read by the pane, which is why
this one can say "nothing here runs on Windows yet" rather than exec'ing a shell
script that cannot run.

The one thing a clone still cannot do is build. pi-doom is a node entry point, a
`.wasm` and `node_modules`, so `bin/doom` fetches and installs it on first run — in a
pane, under a capability you granted, with its output on screen — rather than a README
asking you to do it. That is deliberately not an install-time hook: arbitrary code at
install is a bigger consent question than "hold a process open on my keystrokes".

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
- **No engine is vendored.** pi-doom is **GPL-2.0**, as are other
  doomgeneric-derived ports. `bin/doom` *fetches* it into a cache on your machine, at
  which point you have it under its own licence, from its own repository, with its
  source — which is exactly what a GPL binary shipped from here could not offer
  without this repository carrying that source too. That is why the launcher fetches
  rather than the package vendoring.
- A shareware or commercial WAD is yours to obtain and abide by. None is here.

## Status

Written against branch `thurbox-v2-ui-approach` at **`f1c0b85`** — the program-pane
capability (`953e177`), install-by-clone (`e6e1d532`) and the `tab` documentation fix
(`f1c0b85`) — reading `docs/PLUGINS.md`, `ui/AGENTS.md`, `src/kernel/command.rs`,
`src/kernel/convert.rs`, `src/kernel/terminal.rs`, `src/kernel/host.rs`,
`src/session/plugin_spec.rs`, `src/kernel/packages.rs` and `thurbox.yml`.

Gates: `luac -p`, `selene` against **that commit's** `thurbox.yml` (where
`thurbox.granted` and `thurbox.platform` are declared — an older copy rejects this
file), and `stylua --check` with the pinned `.stylua.toml`. A stub harness exercises
the unsupported-platform, untrusted, running and released states, the every-frame ask,
argument assembly (including a WAD path with a space staying one argument), the
`ui_dir` resolution and its fallbacks, the error path, both chords, the automap hint,
and every emitted node against the fields `convert.rs` accepts.

Measured for real, outside thurbox: `bin/doom` from an empty cache and with no
arguments fetched pi-doom, installed its dependencies, found the shipped WAD, logged
`DOOM initialized (640x400)` and emitted 1,677,680 half-blocks with paired truecolor
runs and no graphics-protocol sequences.

**I have never seen this pane render.** The interface cannot be launched from where
this was written, so no visual claim here comes from a screen — the launcher and the
engine are measured, the pane around them is read from the kernel's source. Also
untested: key releases through the kernel and tmux (see above), and every
`thurbox-cli plugin` command, because the installed CLI is `0.0.0-dev` and has no
`plugin` subcommand.
