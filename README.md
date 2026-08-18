# thurbox-doom

DOOM in a thurbox pane. One Lua file asks the kernel for a program pane, frames it
and owns the key rules; the kernel runs the program in a real terminal, resizes it to
the rect and parses its output into cells. The plugin never sees a frame.

**Everything it needs ships with it, DOOM included.**
`thurbox-cli plugin install git+…` clones this repository into your interface
directory, which brings the pane, a built engine and a freely-redistributable WAD.
Grant the pane one capability and it plays: nothing to configure, nothing to fetch.

```text
<interface dir>/thurbox-doom/plugins/40_doom.lua           the pane
<interface dir>/thurbox-doom/engine/bin/linux-x86_64/doom  DOOM, statically linked
<interface dir>/thurbox-doom/wad/freedoom1.wad             the WAD
```

The binary is **linux-x86_64** only — the one target that could be built *and run*
where this was written. On any other machine the pane names it and points at
`engine/src`, which is a `make` away, or at the `doom.program` setting.

---

## Read this before anything else

**This needs thurbox's v2 plugin kernel, which is not released.** It lives on branch
`thurbox-v2-ui-approach`, open as
**[PR #936](https://github.com/Thurbeen/thurbox/pull/936)** in `Thurbeen/thurbox`.
`main` has no `ui/` directory and no plugin API, so on a released thurbox this file is
inert.

It needs three things from that branch in particular, each named by its commit title
rather than a sha — that branch is rebased when it merges, so any sha quoted here would
stop existing:

- **"let a plugin run an interactive program in a pane it owns"** — the `program`
  capability this pane is built on;
- **"install a plugin by cloning its repository, payload and all"** — how the WAD gets
  to you;
- the fix that lets a **`plugin.toml` name the pane inside a clone**.

On a build older than those, the plugin loads and draws its untrusted panel forever.

**If a repository install fails on Windows**, complaining that

```text
Name contains invalid characters
```

then you have found a known upstream bug and not a problem with your setup. The
installer derived a directory name by splitting the source on `/` and `:`, so a drive
letter's colon split a local path and the whole tail was refused — it never reached the
clone, for *any* source spelling. Nothing about this plugin caused it, but it is this
repository's install you would have watched fail, which is why it is written down.

**Where the fix is, as of writing:** on the same unmerged branch, in the commit
*"name a cloned plugin's directory on Windows too"*, whose Windows CI is green. It is in
**no release** — the newest is v1.8.6 — and it cannot be, because that branch carries the
plugin API itself and has not landed. So updating to a release is not the remedy and never
was: running this plugin already means building from the branch, and the remedy is to
rebuild from it at or after that commit. If the branch has since merged, the first release
after it is the answer instead.

The error string is the anchor here deliberately: it is what you actually see, it is
searchable, and unlike a commit id it cannot be rewritten by a merge.

On that branch the kernel **is** the interface, so it runs as plain **`thurbox`**.
There is no `thurbox2` binary.

**The plugin API is explicitly unstable** (see the banner atop `docs/PLUGINS.md`), and
**plugins are trusted code** — this one asks for a capability that holds a process open
on your keystrokes.

## What it does

- **No DOOM named yet** → a panel asking for one, and showing the WAD it brought.
- **Named but not trusted** → what it would run, and how to grant the capability.
- **Trusted** → it asks for its pane every frame and frames the surface, with a
  controls row underneath.
- **Released** (`ctrl+alt+x`) → the program is stopped and the pane given up, with the
  chord that starts it again.

No session is involved: the pane belongs to the plugin, so there is one DOOM whatever
session is selected, and none is required. Nothing is persisted — the kernel re-finds
the pane by its window name, and `F10` leaves the game running.

There is **no `agents.toml` entry**. An earlier version of this plugin created a
session whose "agent" was DOOM, which is a game pretending to be a coding agent to
borrow the one field of the session model that spawns a pty. The kernel now lends a
plugin its own pane, so that is gone.

## Finding it

`center` is a **switch** slot, so this pane is an alternate behind the agent: it draws
nothing until it is focused. Install it, launch thurbox and you will see the agent pane
— which is why the plugin advertises itself three ways:

- a **DOOM** entry in the action band along the bottom;
- **`f7`** from anywhere (rebindable, and it appears in `F1` help);
- the focus ring — `tab` / `shift+tab`, or `ctrl+h` / `ctrl+l`.

Reported by someone who installed it cold and saw an empty-looking interface, which is
the failure worth avoiding: "installed correctly and appears to have done nothing".

If you would rather have DOOM beside the agent instead of taking turns with it, give
the pane a slot of its own and place that slot in `layout.lua` — two lines, and
`thurbox-cli plugin check` prints the one you need.

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

## The WAD, which does ship here

```text
wad/freedoom1.wad        Freedoom: Phase 1, 0.13.0 — the single-player campaign
wad/COPYING.txt          Freedoom's licence, reproduced as its terms require
wad/CREDITS.txt          the contributor list COPYING.txt refers to
wad/CREDITS-MUSIC.txt    the music credits
```

[Freedoom](https://freedoom.github.io/)
([`freedoom/freedoom`](https://github.com/freedoom/freedoom)) is free game data for the
DOOM engine under a **modified BSD licence** permitting binary redistribution as long
as the notice, conditions and disclaimer travel with it — which is what
`wad/COPYING.txt` is doing there. Phase 1 rather than FreeDM because FreeDM's maps are
deathmatch arenas with no monster placement.

Provenance: extracted from `freedoom-0.13.0.zip`, whose SHA256 matched Freedoom's own
published `freedoom-0.13.0-CHECKSUM` manifest. The shipped file is

```text
sha256  7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d  freedoom1.wad
```

A shareware or commercial WAD is your own affair, and is what the `wad` setting is for.

## Install

The WAD is why this is installed by **cloning** rather than fetched file by file: the
file-by-file path decodes what it fetches as UTF-8, so a WAD through it would be
silently corrupted rather than refused.

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-doom
```

A `git+` prefix, a `.git` suffix or `git@host:path` are the three forms that clone; a
bare `https://…` deliberately does not, because that spelling already means "fetch the
files this manifest names from this base".

The working copy lands at `<interface dir>/thurbox-doom/` and **keeps its `.git`**,
which is what makes `thurbox-cli plugin update` a fetch and what protects your edits:
git will not move a dirty working tree, so a `sync` over a pane you changed reports
`kept`, and `git diff` shows what you did. The entry recorded is:

```toml
[[plugin]]
src  = "git+https://github.com/Thurbeen/thurbox-doom"
file = "thurbox-doom/plugins/40_doom.lua"
```

`install` finds that pane itself: `plugin.toml` names it (`pane.source`), and failing a
manifest it takes the single `.lua` under `plugins/`. The lock records the **commit**,
not the branch, so the same spec and lock reproduce the same bytes elsewhere. Load
order still comes from the `40_` prefix.

> **`thurbox-cli plugin install doom` does not install this.** A bare name resolves
> into the thurbox repository's own examples, where a smaller `doom` pane demonstrates
> the capability.

**What cloning means, plainly:** it puts this repository's files on your disk. Nothing
is executed by installing — and nothing here is executable in any case, since the only
payload is a WAD.

`~/.config/thurbox/ui/` is the interface directory, watched, so the pane appears on
save (120 ms debounce); `F10` forces a reload. `THURBOX_UI_DIR` overrides the path, and
a dev build (`0.0.0-dev`) reads `~/.config/thurbox-dev/ui` instead.

The pane declares `slot = "center"`, which the stock `layout.lua` always places, so
**there is no arrangement edit to make** and `thurbox-cli plugin check` — which fails a
pane whose slot nothing places — has nothing to complain about. The cost is that DOOM
and the agent take turns in the centre; give the pane a slot of its own if you would
rather have both.

**If you build an engine yourself, build it somewhere else.** Two reasons, both about
this directory: it is watched recursively, so a package manager running under it fires
thousands of events and — counter-intuitively — the interface stops reloading rather
than reloading too often, because a burst keeps the debounce rolling forward. And
anything you generate inside the clone makes the tree dirty, which is exactly what
makes `update` report `kept` and refuse to move. A cache under
`${XDG_CACHE_HOME:-~/.cache}` costs nothing and avoids both.

## Trust it

The pane draws a panel until you grant the capability:

```text
settings (ctrl+, or F6) → ] to the Interface tab → select the file → t
```

`program` is a **different grant from `run`**, deliberately. `run` is bounded on every
axis that matters — capped output, a timeout, four at a time — and an interactive
program has none of those and holds your keyboard as well. Trusting a pane to poll
`top` is not the same decision as letting it hold a process open on your keystrokes.

Installing grants nothing. Nothing starts until you say `t`.

## Settings

Declared as data, so they appear in the settings modal and are stored in
`~/.config/thurbox/ui.json`.

| Setting | Default | What it does |
|---|---|---|
| `doom.program` | *(empty → the shipped engine)* | the DOOM to run. Empty resolves to `engine/bin/<os>-<arch>/doom` inside this clone, which exists for `linux-x86_64`; on a machine with no shipped build the pane says so. A relative path resolves in the clone, an absolute one is used as given |
| `doom.wad` | `wad/freedoom1.wad` | WAD, passed as the **last** argument. A **relative** path resolves inside this plugin's clone, so the default is the WAD that came with it; an absolute path is used as given |
| `doom.args` | *(empty)* | extra arguments, split on spaces |
| `doom.footer` | `true` | draw the controls row (it costs the game one row) |

`program` is empty in the modal rather than pre-filled with a path, because what it
resolves to depends on the machine: the pane asks `thurbox.platform` and looks for the
build this repository ships for that `os-arch`. It knows which ones were committed, so
it never exec's a path it has no reason to believe in — on an unshipped platform it
names the machine and offers the two ways forward. `wad` is simpler: one file ships, so
its default **names that file**.

The pane shows those paths **in full**, wrapped rather than truncated, because a path
you are meant to copy is no use with its filename cut off — a long interface directory
was doing exactly that.

**Paths.** A relative `wad` resolves inside this plugin's clone
(`<interface dir>/thurbox-doom/`), which is where its own files are. Everything else
wants an absolute path: a program pane has no session and therefore no repository, so
the kernel runs the program in the interface directory, and a relative `program` would
resolve against `~/.config/thurbox/ui/` rather than where you meant.

**Why `wad` is separate from `args`.** Arguments are passed as a list and quoted
individually, so a WAD path containing a space survives as one argument. `args` is
split on whitespace for flags; the path that must not be split has its own field.

## Controls

Everything the plugin does not claim goes to the program, because it declares
`input = "session"`.

| Action | Keys |
|---|---|
| move | `↑` `↓` `←` `→`, or `w` `a` `s` `d` |
| turn | `q` `e` |
| fire | `f`, or any `ctrl` chord |
| use / open | `space` |
| run | `r` |
| strafe | `,` `.` |
| weapons | `1`–`7` |
| automap | `tab` |
| menu / back | `esc` |

Those are the shipped engine's, and they are DOOM's own where a terminal can express
them plus substitutes where it cannot: nothing can see a bare `shift` or `ctrl` held
down, so `r` runs and `f` fires. A `program` of your own will have its own map.

| Chord | Does |
|---|---|
| `f7` | show the DOOM pane (global) |
| `ctrl+alt+r` | restart DOOM in this pane |
| `ctrl+alt+x` | stop it and give up the pane |

`f7` is global, so it reaches a pane you cannot yet see; the other two are
plugin-scoped and fire only while this pane has focus. All three are rebindable
(`~/.config/thurbox/ui.json`). The pane-scoped two are `ctrl+alt+`
chords because a declared chord is consumed before the surface ever sees it, and DOOM
wants every bare key there is — the letters included, for cheats.

### Held keys, and why this engine handles them

thurbox **cannot deliver key-release events**, and that is a kernel limitation with
two independent causes, both confirmed upstream: its terminal layer asks the outer
terminal for `DISAMBIGUATE_ESCAPE_CODES` and never `REPORT_EVENT_TYPES` — the Kitty
flag that makes releases reported at all — and its event loop matches
`KeyEventKind::Press`, so a release would be dropped even if one arrived. It is
recorded upstream as **D12**, deliberately not fixed: forwarding a release needs an
encoding the key path does not have, and getting it wrong would double keystrokes in
every agent pane, which is worse than a latched key in a game.

A port that waits for a release therefore walks you into a wall. **The shipped engine
does not wait.** A key is released once it has been quiet for `-release <ms>`
(default 90), because auto-repeat keeps a held key arriving — so holding a direction
moves you and letting go stops you. Tune it by adding `-release 60` to `doom.args` if
your terminal repeats slowly or quickly.

If you point `doom.program` at some other DOOM, this is the property to check first.
Earlier revisions of this README suggested `set -g extended-keys on` in `~/.tmux.conf`:
**that was wrong** and is gone — tmux is not the layer dropping them.

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

Nor is it a package that ships an engine. An engine is a GPL binary — which would
oblige this repository to carry its corresponding source — or a build tree with its own
package manager, which does not belong under a watched interface directory. Shipping
the data and naming the requirement is the honest division.

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

**`wad/freedoom1.wad` is Freedoom's modified BSD licence**, which requires the notice,
conditions and disclaimer to accompany it: `wad/COPYING.txt` and `wad/CREDITS.txt` are
that accompaniment, and removing them would break the terms.

So three licences in three directories: MIT for the pane, GPL-2.0 for the engine, BSD
for the data. A shareware or commercial WAD you supply yourself is your own affair.

## Status

Written against branch `thurbox-v2-ui-approach` — at the point where install-by-clone,
the `program` capability and manifest-named panes had all landed — reading
`docs/PLUGINS.md`, `ui/AGENTS.md` and the kernel sources for the contract.

Gates: `luac -p`, `selene` against the `thurbox.yml` **from the branch you build
against** (the sandbox definition, where `thurbox.granted` and `thurbox.platform` are
declared, so an older copy rejects this file), and `stylua --check` with the pinned
`.stylua.toml`. A stub harness — kernel globals faked, `lib/theme.lua`,
`lib/widgets.lua` and `lib/settings.lua` the real files — covers the shipped-engine and
unshipped-platform states, untrusted, running and released, the every-frame ask, argv
assembly (relative and absolute `program` and `wad`, a path with a space, a
Windows-shaped `ui_dir`), the long-path wrapping, both chords, the pill, the automap
hint, and every emitted node against the fields `convert.rs` accepts.

**The engine is measured, the pane is not.** The committed binary was built and run
here: statically linked, 1.5 MB, playing the shipped WAD, emitting ~297k half-blocks
with paired truecolor runs and zero graphics-protocol bytes at ~0.7 MB/s. The pane
around it has been seen to render by the maintainer of the v2 branch, in their terminal,
at an earlier commit — not by me, and not with this engine in place. Also unrun here:
every `thurbox-cli plugin` command, because the installed CLI is `0.0.0-dev` and has no
`plugin` subcommand.
