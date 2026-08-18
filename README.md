# thurbox-doom

DOOM as a thurbox pane. The plugin is one Lua file: it places and frames a live
PTY `surface`, decides which session it shows, and owns the key rules. The kernel
fills the rect with cells. A freely-redistributable WAD ships alongside it, so
only the DOOM port itself is left for you to build.

The thing running DOOM is **not** this plugin. It is a native terminal DOOM port
running as an ordinary thurbox **session**, parsed by the kernel's vt100 parser
and painted into the rect this plugin asks for.

---

## Read this before anything else

**This needs thurbox's v2 plugin kernel, which is not released.** It lives on
branch `thurbox-v2-ui-approach`, open as
**[PR #936](https://github.com/Thurbeen/thurbox/pull/936)** ("feat(ui)!: replace
the v1 interface with the plugin kernel") in `Thurbeen/thurbox`. `main` has no
`ui/` directory and no plugin API at all, so on a released thurbox this file is
inert — there is nothing to load it.

On that branch the kernel **is** the interface, so it runs as plain **`thurbox`**.
There is no `thurbox2` binary; do not look for one.

**The plugin API is explicitly unstable.** The banner at the top of
`docs/PLUGINS.md` says it will change without a deprecation period until it
settles. This file will need edits when it does.

**Plugins are trusted code.** They run in-process with whatever capabilities the
kernel grants, exactly like a shell extension. Install one the way you would
install a shell script from a stranger — read it first. This one is ~470 lines,
a third of them comments.

## What the pane does

Two render states:

- **No DOOM session yet** — a launcher panel: what it is, what it needs, the key
  that launches it, and the error from a previous attempt if there was one.
- **A DOOM session exists** — its `surface`, framed, with a row of controls under
  it.

Launching is `command("create", { repo = …, text = "doom", agent = "doom" })`
followed by `command("focus", { text = "doom" })`. The session is found again in
later snapshots by its agent name, because commands return nothing: a `create`
is accepted instantly and the session it makes arrives in a snapshot with an id
this plugin never saw.

**It needs no `capabilities`.** There is no `run`, so there is no trust gate to
pass and no "untrusted" state to draw. The DOOM process is a *session*, which the
kernel already owns and already knows how to attach, scroll, restart and delete.
That is a genuine advantage over a `run`-based pane: `run` completes and then
reports, so it could never carry a game, and it would demand the user's trust
before drawing anything at all.

## Prerequisites

One of the two ships with this repository. You need to build the port; the WAD is
already here.

### A terminal DOOM port

**[`wojciech-graj/doom-ascii`](https://github.com/wojciech-graj/doom-ascii)** —
the one this is written for, and the one I tested. C, GPL-2.0, a source port of
[doomgeneric](https://github.com/ozkl/doomgeneric). No sound.

```bash
git clone https://github.com/wojciech-graj/doom-ascii
cd doom-ascii && make          # → _unix/game/doom-ascii
```

What I verified, on Linux at commit `b5188d7` (version 0.3.1):

- `make` with no arguments builds it (warnings only, no errors) and puts the
  binary at `_unix/game/doom-ascii`.
- It needs a **tty**: with stdout redirected to a file it exits
  `DG_Init: tcgetattr error 25`. A thurbox session is a PTY, which is exactly
  what it wants.
- `-iwad <path>` names the WAD. Without it, it looks for `doom2.wad`,
  `plutonia.wad`, `tnt.wad`, `doom.wad`, `doom1.wad`, `chex.wad`, `hacx.wad`,
  `freedm.wad`, `freedoom2.wad`, `freedoom1.wad` **in the working directory** and
  then gives up.
- Its output is **styled text**, which is what makes it fit a cell surface. Over
  ~10 s of play with FreeDM I measured 1,638,647 truecolor `ESC[38;2;R;G;Bm`
  spans, and **zero** Kitty-graphics or Sixel sequences. The only CSI kinds it
  emits are `m` (colour), `H` (cursor position) and `J` (erase) — a plain vt100
  repertoire.
- It writes `.default.cfg` and its saves into the **working directory**, which is
  the session's directory. See [Settings](#settings) below.

**[`cryptocode/terminal-doom`](https://github.com/cryptocode/terminal-doom)** —
the repo exists (doomgeneric + [libvaxis](https://github.com/rockorager/libvaxis),
built with `zig build -Doptimize=ReleaseFast` on Zig 0.16), and it is the nicer
of the two to look at. **I did not test it, and I do not expect it to work in
this pane.** Its README describes rendering each frame as a base64 payload
wrapped in the **Kitty graphics protocol** envelope; a thurbox `surface` carries
**cells**, so a graphics-protocol image has nothing to be parsed into. Try it if
you like — if it works, I would like to know how.

Other ports may work: the requirement is that the port paints with ordinary text
and SGR colour, and reads its keys from stdin.

### A WAD — included

**A WAD ships with this repository**, so you do not have to go and find one:

```text
wad/freedoom1.wad        Freedoom: Phase 1, 0.13.0 — the single-player campaign
wad/COPYING.txt          Freedoom's licence, reproduced as its terms require
wad/CREDITS.txt          the contributor list COPYING.txt refers to
wad/CREDITS-MUSIC.txt    the music credits
```

[Freedoom](https://freedoom.github.io/)
([`freedoom/freedoom`](https://github.com/freedoom/freedoom)) is free game data
built for the DOOM engine, under a **modified BSD licence** that permits binary
redistribution as long as the notice, conditions and disclaimer travel with it —
which is what `wad/COPYING.txt` is doing there. Phase 1 rather than FreeDM
because FreeDM's maps are deathmatch arenas with no monster placement, so solo
play in a pane would be a walk around an empty level.

Provenance, so you need not take my word for it: extracted from
`freedoom-0.13.0.zip`, whose SHA256 matched Freedoom's own published
`freedoom-0.13.0-CHECKSUM` manifest. The file shipped here is

```text
sha256  7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d  freedoom1.wad
```

I loaded this exact file with the port built above: it announces
`Freedoom: Phase 1` and plays. It also prints a warning inherited from
chocolate-doom — "You are playing using one of the Freedoom IWAD files, which
might not work in this port" — and then proceeds anyway; that banner is expected,
not a symptom.

`freedoom2.wad` and `freedm.wad` from the same release work too if you would
rather; point `-iwad` at whichever you like. A shareware `doom1.wad` or a
commercial `doom.wad` / `doom2.wad` is your own affair, and **no port and no
binary is vendored here** — you build that yourself, above.

## agents.toml

Register the port as an agent named `doom` in `~/.config/thurbox/agents.toml`:

```toml
[[agents]]
name = "doom"
command = "/home/you/src/doom-ascii/_unix/game/doom-ascii"
args = ["-iwad", "/home/you/src/thurbox-doom/wad/freedoom1.wad"]
```

Both paths are **absolute and yours to correct**: the first is wherever you built
the port, the second is wherever you cloned this repository. The WAD stays in the
clone — only `doom.lua` is copied into the interface directory — so keep the
checkout around, or move the WAD somewhere of your own and name that instead.

Three things about that snippet:

- **`args` are POSIX-quoted, so a literal `~` never expands.** Use an absolute
  path, or `{home}`, which thurbox substitutes with the resolved home directory at
  spawn time (the *remote* home for an SSH or WSL host). This is documented
  behaviour of `agents.toml`, not a guess.
- `command` may equally be a **wrapper script** that adds `-iwad`, `-scaling`,
  `-chars block` and whatever else you want, in which case `args` can stay `[]`.
- **`agents.toml` reloads live** — thurbox polls its mtime about once a second and
  toasts the reload. No restart, and no need to leave the interface.

The agent name `doom` is the contract: it is what the launch asks for, and how
the pane recognises the session afterwards. Register it under another name and the
pane will not find it.

## Install

The v2 branch grew a **pane package manager** (`plugins.toml` + `plugins.lock`,
and `thurbox-cli plugin install|sync|update|remove|available`), and this
repository is a package: `plugin.toml` at its root names the pane and where it
lands.

From a clone:

```bash
git clone https://github.com/Thurbeen/thurbox-doom ~/src/thurbox-doom
thurbox-cli plugin install ~/src/thurbox-doom
```

Or straight from GitHub's raw host, no clone:

```bash
thurbox-cli plugin install https://raw.githubusercontent.com/Thurbeen/thurbox-doom/main
```

Either way the pane lands at `plugins/40_doom.lua` under your interface directory
and the entry is written into `plugins.toml` beside it:

```toml
[[plugin]]
src  = "https://raw.githubusercontent.com/Thurbeen/thurbox-doom/main"
file = "plugins/40_doom.lua"
```

`--as plugins/NN_doom.lua` puts it somewhere else — the number is load order.
After hand-editing that spec, `thurbox-cli plugin sync` converges the directory
and its exit status says whether it worked; `plugins.lock` records what each entry
resolved to and the digest of every file delivered, so committing both reproduces
the same interface elsewhere. An edit you make to an installed file is preserved
and reported as `kept`, and deleting one is remembered rather than undone.

Four things worth knowing before you reach for it:

- **The WAD is not installed by any of this.** A package may deliver **Lua only**
  — every declared destination must end in `.lua` — so `plugin install` brings
  `doom.lua` and nothing else. Keep the clone (or move `wad/freedoom1.wad`
  somewhere of your own) and name it by absolute path in `agents.toml`. Installing
  from the raw URL means you have no WAD yet; clone or download one.
- **`doom` is not a bare name you can install.** A bare `src` resolves to
  `ui-plugins/<name>` *inside the thurbox repository* at your binary's release
  tag. This pane lives here, so it is a URL or a path.
- **A pin only means something for a bare name.** `src` here is a URL, so `pin` is
  recorded and otherwise ignored — pin the git ref **in the URL** (a tag or commit
  sha in place of `main`) if you want the entry to stay put.
- **Installing grants nothing.** That matters less here than for most panes: this
  one declares no `capabilities`, so there is nothing to trust. The Interface tab
  will show it as `from <src>` rather than `yours`, which is the useful half —
  where a file came from.

By hand still works, and the manager is a convenience rather than a gate:

```bash
cp doom.lua ~/.config/thurbox/ui/plugins/40_doom.lua
```

A file you copied is `yours` in the inventory: nothing will update it, and nothing
will take it back.

`~/.config/thurbox/ui/` is the interface directory (`docs/CONFIG.md`), and
`plugins/*.lua` is one file per pane. The directory is watched, so the pane
appears on save (120 ms debounce); `F10` forces a reload. Two things override that
path: `THURBOX_UI_DIR` if it is set, and a **dev build** (version `0.0.0-dev`),
which reads `~/.config/thurbox-dev/ui` instead so a checkout cannot touch your
installed setup.

The pane declares `slot = "center"`, which the stock `layout.lua` always places —
so there is no `layout.lua` edit to make, and nothing here writes your arrangement
anyway. This matters more than it did: `thurbox-cli plugin check` now **fails** a
pane that loads but whose slot no arrangement places, printing the `layout.lua`
line to add. Reading `layout.lua`, `center` is placed at every width — it is the
one slot never dropped — so this pane should pass that check. I could not run it
(see below).

The `plugin` subcommands are **not** available on the `thurbox-cli` I have here
(`0.0.0-dev`, which reports `unrecognized subcommand 'plugin'`), so none of the
commands above were executed — they are transcribed from the branch's
`docs/PLUGINS.md`, `src/kernel/packages.rs` and `src/session/plugin_spec.rs`. The
`cp` is the one instruction I can vouch for from this machine.

## Settings

Declared as data, so they appear in the settings modal (`Ctrl+,` / `F6`) and are
stored in `~/.config/thurbox/ui.json`.

| Setting | Default | What it does |
|---|---|---|
| `doom.dir` | `~` | the directory the DOOM session is created in |
| `doom.footer` | `true` | draw the controls row under the game (it costs the game one row) |

`command("create")` **requires** a `repo`, and DOOM does not have one — so this is
a deliberate choice rather than a meaningful value. The kernel expands a `~` for a
local session and the only check it makes is that the path is a directory; no
`branch` is passed, so no worktree is cut and the directory does not have to be a
git repository. It is not arbitrary either: `doom-ascii` writes `.default.cfg` and
its save games into the session's working directory, so pointing `doom.dir` at a
directory of your own is how you keep your keybindings and your saves.

One honest caveat about `doom.dir`: the confirmed way for a plugin to read a
declared setting back is `lib.settings.enabled(plugin, id, default)`, which is a
**boolean** reader. A string-valued setting is therefore read defensively — the
plugin probes `lib.settings` for a value-style reader and falls back to the
declared default when there is none. Worst case the pane launches in `~` and that
row does not take effect; it will not throw either way. `doom.footer` is a boolean
and uses the confirmed reader.

## Controls

`p` while the pane has focus launches DOOM (or brings a running session forward).
Everything else goes straight to the game: the pane declares `input = "session"`,
so keys it does not handle reach the pty untouched.

| Action | Key |
|---|---|
| move | `↑` `↓` `←` `→` |
| strafe | `,` `.` |
| fire | `space` |
| use / open | `e` |
| run | `]` |
| weapons | `1`–`7` |
| menu | `esc` |

Those are `doom-ascii`'s defaults, remappable in its own `.default.cfg`. `p` is
bound by this plugin precisely *because* vanilla DOOM binds nothing to it — a
declared chord is consumed before the pty ever sees it, so binding the launch key
onto something DOOM wants would take that key away from the game. It is rebindable
(rebindings live in `~/.config/thurbox/ui.json`, editable by hand or from the
interface's help and Interface tab), and it appears in `F1` help because it is
declared as data.

### Two caveats that would otherwise read as bugs

**1. Reserved keys cannot reach DOOM.** `ctrl+q` (quit), `f10` (reload), `tab` and
`shift+tab`, `ctrl+h` / `ctrl+l` (focus) and `f12` (perf counters) are reserved by
the kernel — which is what stops a misbehaving pane from trapping you inside it.
No plugin can consume them, this one included.

**`tab` is DOOM's automap**, so the automap does not reach the game. Rebinding is
where you would look — chord overrides live in `~/.config/thurbox/ui.json`, written
by the interface's help and Interface tab or by hand — but be warned that
`docs/PLUGINS.md` says the reserved chords "cannot be rebound **or** consumed", so
on the branch I read against it is not clear that moving focus off `tab` is even
offered. I could not try it. Either way it is the kernel's rule, not something this
plugin can work around.

**2. Key-release events.** DOOM wants press *and* release to move smoothly.
Releases only arrive over the kitty keyboard protocol, and tmux — which thurbox
runs its sessions in — is the layer most likely to drop them. The setting to try is
`set -g extended-keys on` in `~/.tmux.conf`.

I have **not** tested this end to end, and two things temper the worry:

- On the tmux I checked (3.7b, where `extended-keys` was already `on`), the manual
  documents `extended-keys` as the `modifyOtherKeys` equivalent — reporting
  *modified* keys — and mentions neither the kitty keyboard protocol nor
  key-release events at all. So `extended-keys on` is worth trying, but nothing I
  read promises releases survive the trip.
- **`doom-ascii` does not need them.** Reading `src/doomgeneric_ascii.c`, it keeps
  a timestamp per key and synthesises the release itself once a key has been quiet
  for `keypress_smoothing_ms` — 42 ms by default, settable with `-kpsmooth <ms>`.
  So movement rides on your terminal's key-*repeat* rate rather than on releases,
  and `-kpsmooth` is the knob to turn if movement feels jittery or sticky. A port
  that expects real releases will fare worse.

### Throughput

Worth knowing before you blame the pane: over ~10 s of play at the default
`-scaling 4`, `doom-ascii` emitted ~36.8 MB — about 700 frames of ~53 KB each,
1.6 M colour spans — through the pty. (That capture used FreeDM; the vendored
Phase 1 WAD behaves the same way, at ~21 MB over a shorter ~6 s run.) thurbox's vt100 parser consumes all of it
while paints are capped at 60 fps, so the surface shows the latest state rather
than every frame. I measured this outside thurbox, under `script`; I have **not**
measured what it costs inside the interface. `-scaling` (larger number, smaller
picture) is the first thing to turn down.

## What this deliberately is not

A Lua software renderer. It is *expressible* — `surface` takes Lua-supplied styled
runs and the kernel's `parse_color` accepts `#rrggbb` as truecolor — but there is
no way to get frames into Lua. The sandbox has no WASM runtime, no ffi, no
filesystem and no timer of its own, and `run` completes rather than streams.

The arithmetic is against it too. A renderer emitting one styled run per cell
spends ~4,000 runs a frame at 80×50, and even `doom-ascii`'s own run-length-coded
output averaged ~2,300 colour spans a frame in my capture — against a renderer
whose hottest measured style-conversion path is ~100 spans a pane
(`src/kernel/convert.rs`, per `docs/V2-KERNEL.md`). The PTY route costs none of
it: the cells never pass through Lua at all.

## Credits

- **id Software**, for DOOM.
- **[`wojciech-graj/doom-ascii`](https://github.com/wojciech-graj/doom-ascii)**,
  the port this pane is written for, and
  **[doomgeneric](https://github.com/ozkl/doomgeneric)** beneath it.
- **[`badlogic/pi-doom`](https://github.com/badlogic/pi-doom)**, for prior art:
  DOOM inside a terminal agent's UI, done by running the game **in-process as
  WASM** and painting the frames itself. thurbox takes the PTY route instead
  because the Lua plugin sandbox cannot do that one: no WASM runtime, no
  filesystem, no clock of its own, and it never sees a frame. What it does have is
  a kernel that already runs processes as sessions and already renders their
  terminals — so the game is a session, and this plugin is only the frame around
  it.

## Licences

This plugin is MIT (see [`LICENSE`](LICENSE)) — Copyright (c) 2026 Thurbeen,
matching `Thurbeen/thurbox`.

The rest is not. **DOOM, the ports and the WADs carry their own licences.**

- **`wad/freedoom1.wad` ships here** under Freedoom's **modified BSD licence**,
  which permits binary redistribution provided the copyright notice, conditions and
  disclaimer accompany it: `wad/COPYING.txt` and `wad/CREDITS.txt` are that
  accompaniment, and removing them would break the terms. Freedoom is not
  MIT-licensed and the `LICENSE` at the root does not cover it.
- **No port and no binary is vendored.** `doom-ascii` and other
  doomgeneric-derived ports are **GPL-2.0** — you build one yourself, from its own
  repository, under its own licence. Shipping a GPL binary here would oblige this
  repository to carry its corresponding source too, which is a deliberate
  non-goal.
- A shareware or commercial WAD is yours to obtain and abide by. None is here.

## Status

The plugin was written against a pinned copy of the v2 branch at `077004d`; the
install instructions above were rewritten against its current head, `7f814f5`
("feat(ui): give panes a package manager, and make an unplaced one fail loudly"),
read from GitHub. Nothing the package manager does was exercised here — see the end
of the Install section.

Checked with `luac -p`, `selene`
against the plugin sandbox definition (`thurbox.yml`, which declares the VM's real
stdlib and marks what is withheld), and `stylua`. I also ran it under a stub
harness — the kernel's globals faked, `lib/theme.lua` and `lib/widgets.lua` the
real files — which exercises both render states, a deleted session, an attach
failure, narrow panes, the key rules and the launch commands, and checks every node
it emits against the fields `src/kernel/convert.rs` accepts.

That harness is not the kernel. **I have never seen this pane render** — the
interface cannot be launched from where this was written — so treat every visual
claim as derived from reading `src/kernel/convert.rs`, `src/kernel/command.rs` and
`ui/plugins/20_agent.lua` rather than from a screen. The port measurements above
are real, and were taken outside thurbox.
