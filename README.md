# thurbox-doom

DOOM in a thurbox pane. One Lua file asks the kernel for a program pane, frames it
and owns the key rules; the kernel runs the program in a real terminal, resizes it to
the rect and parses its output into cells. The plugin never sees a frame.

**It ships game data, not a game.** A freely-redistributable WAD travels with the
plugin; which DOOM to run is one setting, and yours to choose.

```text
<interface dir>/thurbox-doom/plugins/40_doom.lua   the pane
<interface dir>/thurbox-doom/wad/freedoom1.wad     the WAD
```

---

## Read this before anything else

**This needs thurbox's v2 plugin kernel, which is not released.** It lives on branch
`thurbox-v2-ui-approach`, open as
**[PR #936](https://github.com/Thurbeen/thurbox/pull/936)** in `Thurbeen/thurbox`.
`main` has no `ui/` directory and no plugin API, so on a released thurbox this file is
inert.

It needs three things from that branch in particular: the **program-pane capability**
(`953e177`), **install-by-clone** (`e6e1d532`), and — for the manifest to name the pane
inside a clone — `4c15f5b`. On an older build it loads and draws its untrusted panel
forever.

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

## What to point it at

Any terminal DOOM that meets three conditions:

1. **It paints text cells** — ordinary characters and SGR colour. A surface carries
   *characters*, so a port that paints images through a terminal graphics protocol
   (Kitty graphics, Sixel) has nothing to be parsed into and will not render here.
   Half-blocks, block elements, braille and plain ASCII are all cells.
2. **It reads its keys from stdin**, which is what `input = "session"` forwards.
3. **It takes a WAD path.** This plugin appends the WAD as the *last* argument; a port
   wanting a flag takes it from the `args` setting, so `args = "-iwad"` gives you
   `-iwad <wad>`.

One property is worth choosing on, because of a kernel limitation documented below:
**prefer a port that derives key-up from timing** — one that treats a key as released
after a quiet interval — over one that waits for real release events. The second kind
will latch held keys inside this pane, and no configuration fixes it.

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
| `doom.program` | *(empty — required)* | the terminal DOOM to run. Until it is set the pane starts nothing and says so |
| `doom.wad` | *(empty)* | WAD, passed as the **last** argument. Empty means the one this repository brought, at `<interface dir>/thurbox-doom/wad/freedoom1.wad` |
| `doom.args` | *(empty)* | extra arguments, split on spaces |
| `doom.footer` | `true` | draw the controls row (it costs the game one row) |

There is no default `program`, because nothing here could honestly supply one: a guess
would be a path that does not exist on most machines, and "no such file or directory"
is a worse first impression than a pane that says what it needs.

**Absolute paths.** A program pane has no session and therefore no repository, so the
kernel runs it locally in the interface directory — a relative path resolves against
`~/.config/thurbox/ui/`, which is not what you meant.

**Why `wad` is separate from `args`.** Arguments are passed as a list and quoted
individually, so a WAD path containing a space survives as one argument. `args` is
split on whitespace for flags; the path that must not be split has its own field.

## Controls

Everything the plugin does not claim goes to the program, because it declares
`input = "session"`.

| Action | Keys |
|---|---|
| move | `↑` `↓` `←` `→` |
| fire | `ctrl` |
| use / open | `space` |
| run | `shift` |
| strafe | `,` `.` |
| weapons | `1`–`7` |
| automap | `tab` |
| menu | `esc` |

Those are **DOOM's own defaults**, not a particular port's — this plugin ships no
engine, so it has no business claiming one's key map. A port that rebinds them will
disagree with that row; most take a config file of their own.

| Chord | Does |
|---|---|
| `ctrl+alt+r` | restart DOOM in this pane |
| `ctrl+alt+x` | stop it and give up the pane |

Both are plugin-scoped, so they fire only while this pane has focus, and both are
rebindable (`~/.config/thurbox/ui.json`). They are `ctrl+alt+` chords because a
declared chord is consumed before the surface ever sees it, and DOOM wants every bare
key there is — the letters included, for cheats.

### Held keys latch, and that is a kernel limitation

**Confirmed, not suspected, and there is nothing you can configure.** A port that
waits for real key-*release* events will never get one inside a pane, so a held
direction key stays down and you keep walking.

Two independent causes, both in the kernel, reported by this plugin and confirmed
upstream:

1. `push_keyboard_enhancement` asks the outer terminal for
   `DISAMBIGUATE_ESCAPE_CODES` and never `REPORT_EVENT_TYPES` — the Kitty flag that
   makes a terminal report releases at all. The outer terminal is never asked, so
   there is nothing to deliver.
2. The event loop matches `KeyEventKind::Press`, so a release would be dropped even if
   one arrived.

It is recorded as **D12** in `openspec/changes/v2-plugin-programs/`' design, with the
shape of a fix: forwarding a release needs an encoding `key_to_bytes` does not have,
and should only reach a program that asked for it by writing `CSI > 3 u` to its own
pty — get that wrong and every agent pane doubles its keystrokes, which is a worse
failure than a latched key in a game. So it is a known limitation rather than an
oversight.

Earlier versions of this README suggested `set -g extended-keys on` in `~/.tmux.conf`.
**That was wrong** and is removed: tmux is not the layer that drops them. Choose a port
that derives key-up from timing and this does not arise.

### Retracted: `tab` works

Earlier versions said `tab` was reserved by the kernel for focus, so DOOM's automap was
unreachable. That was wrong. The reserved set is `ctrl+q`, `f10`, `ctrl+h`, `ctrl+l`
and `f12`; `tab` is forwarded to the focused pane on purpose, because every coding
agent needs it for completion. **The automap works.** The kernel's own `F1` help and
`docs/PLUGINS.md` claimed otherwise; both were fixed upstream in `f1c0b85` after this
plugin reported it.

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

- **id Software**, for DOOM.
- **[Freedoom](https://freedoom.github.io/)**, for game data anyone may ship.

## Licences

This plugin is MIT (see [`LICENSE`](LICENSE)) — Copyright (c) 2026 Thurbeen, matching
`Thurbeen/thurbox`.

`wad/freedoom1.wad` is **not** MIT. It ships under Freedoom's **modified BSD** licence,
which requires the notice, conditions and disclaimer to accompany it: `wad/COPYING.txt`
and `wad/CREDITS.txt` are that accompaniment, and removing them would break the terms.

No engine ships here, so no engine licence applies to this repository. Whatever you
point `program` at is yours to obtain and abide by — DOOM ports are commonly GPL-2.0 —
and a shareware or commercial WAD likewise.

## Status

Written against branch `thurbox-v2-ui-approach` at `4c15f5b`, reading
`docs/PLUGINS.md`, `ui/AGENTS.md`, `src/kernel/command.rs`, `src/kernel/convert.rs`,
`src/kernel/terminal.rs`, `src/kernel/host.rs`, `src/session/plugin_spec.rs`,
`src/kernel/packages.rs` and `thurbox.yml`.

Gates: `luac -p`, `selene` against **that branch's** `thurbox.yml` — where
`thurbox.granted` and `thurbox.platform` are declared, so an older copy rejects this
file — and `stylua --check` with the pinned `.stylua.toml`. A stub harness (kernel
globals faked, `lib/theme.lua`, `lib/widgets.lua` and `lib/settings.lua` the real
files) exercises the unconfigured, untrusted, running and released states, the
every-frame ask, argument assembly including a WAD path with a space staying one
argument, the `ui_dir` resolution and its fallbacks, a whitespace-only `program`
counting as unset, the error path, both chords, the automap hint, and every emitted
node against the fields `convert.rs` accepts.

**I have never seen this pane render.** The interface cannot be launched from where
this was written, so no visual claim here comes from a screen — it is read from the
kernel's source. Also untested: every `thurbox-cli plugin` command, because the
installed CLI is `0.0.0-dev` and has no `plugin` subcommand.
