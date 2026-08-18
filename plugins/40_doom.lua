-- DOOM, in a pane of its own.
--
-- The pane holds a real terminal for a program this plugin names: keystrokes go
-- to it, the kernel resizes it to the rect and parses its output into cells. This
-- file places and frames it and owns the key rules; it never sees a frame.
--
-- WHAT CHANGED, AND WHY THIS FILE IS SHORTER THAN IT WAS. The first version had
-- no way to start a process, so it created a SESSION whose agent was a `doom`
-- entry in `agents.toml` — a game pretending to be a coding agent to borrow the
-- one field of the session model that spawns a pty. That entry is gone. The
-- kernel now lends a plugin its own program pane, so with it went the registry
-- entry, the session-id reconciliation, and the `on_key` guard that existed to
-- stop stray keystrokes reaching somebody else's agent.
--
-- Three things follow from the pane being OURS rather than a session's:
--
--   * There is one DOOM whatever session is selected, and no session at all is
--     required. The name below is scoped to this plugin by the kernel — we supply
--     the name, it supplies the owner — so naming another plugin's pane is not
--     something that can be attempted.
--   * Nothing is persisted. The pane is re-found by its window name, so there is
--     no id to remember and none to go stale. `state` here holds one flag about
--     what the USER asked for, and nothing about what exists.
--   * Keys route to what this pane is SHOWING. Draw no surface and there is
--     nothing to forward to, which is why the panels below need no key guard.
--
-- WHAT THIS IS NOT: a Lua renderer. `surface` does take Lua-supplied styled runs,
-- but there is no way to get frames into Lua — no WASM runtime, no ffi, no
-- filesystem — and a frame is thousands of styled runs against a conversion path
-- whose hottest measured case is ~100 spans a pane. The cells never pass through
-- Lua at all, which is the whole point of a surface.

local theme = require("lib.theme")
local widgets = require("lib.widgets")
local settings = require("lib.settings")

local NAME = "doom"

--- This plugin's pane. Letters, digits, `-` and `_` only: the name reaches a tmux
--- window name, which tmux parses as part of a target string.
local PANE = "doom"

--- This repository's working copy, inside the interface directory.
---
--- `thurbox-cli plugin install git+<url>` clones a plugin that carries a payload,
--- and the clone lands at `<interface dir>/<repository name>/` — so this is the
--- REPOSITORY's name, not the plugin's. What it carries is one thing:
---
---     <interface dir>/thurbox-doom/wad/freedoom1.wad
---
--- A WAD, and nothing else. No engine ships here and none is fetched: which DOOM to
--- run is the `program` setting, and until that is set this pane starts nothing.
--- Deliberate — an engine is a GPL binary or a build tree with its own package
--- manager, and neither belongs in a pane's repository.
local CLONE_DIR = "thurbox-doom"

--- The WAD this repository ships, as the `wad` setting's DECLARED default.
---
--- Relative, and declared rather than resolved at read time, because the settings modal
--- shows a declaration: an empty default reads as "no WAD" to anyone who has not read
--- the README, which is the wrong thing to tell them about the one file this package
--- delivers. Relative to the clone, so it stays true whatever the interface directory
--- turns out to be — resolution happens below.
local PAYLOAD_WAD = "wad/freedoom1.wad"

--- A path inside this repository's working copy, or nil when the kernel has not
--- published where the interface lives.
---
--- Absolute on purpose. A program pane has no session and therefore no repository,
--- so the kernel runs it in the interface directory — a relative path would happen
--- to work today and break the day that changes.
---
--- The join uses `/` on every platform, so on Windows the result has MIXED separators
--- (`C:\Users\me\…\ui/thurbox-doom/wad/freedoom1.wad`). That is safe for a specific
--- reason worth stating rather than assuming: Windows file APIs accept both
--- interchangeably, and this string's only destination is a program's argv — the engine
--- opens it. It would stop being safe if it were ever handed to something doing its own
--- path parsing, which is the change to notice.
---
--- Only the TRAILING separator is normalised, and both spellings are stripped there,
--- because at the end of a directory path both are unambiguously separators. Interior
--- bytes are left alone: a backslash is a legal filename character on POSIX, so
--- stripping one anywhere else would rename somebody's directory. Written down because
--- a separator assumption has twice shipped green from Linux in the kernel this runs
--- on — the second time it broke every repository install.
--- Is this path already absolute? POSIX, a Windows drive letter, or a UNC share.
local function absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
end

local function payload(name)
  local dir = thurbox and thurbox.ui_dir
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return (dir:gsub("[/\\]+$", "")) .. "/" .. CLONE_DIR .. "/" .. name
end

local OPEN, RESTART, RELEASE = "doom.open", "doom.restart", "doom.release"

-- --- settings ---------------------------------------------------------------
--
-- These replace what used to be an `agents.toml` entry. Declared as data, so they
-- reach the settings modal and are stored in `ui.json`, and read back through
-- `lib.settings`, whose `get` returns the user's override or the declared default.

local function setting(id, fallback)
  local value = settings.get(NAME, id, fallback)
  if value == nil then
    return fallback
  end
  return value
end

--- The program to run, or nil when nothing is configured.
---
--- No default, because nothing here can honestly supply one. A guess would be a path
--- that does not exist on most machines, and "no such file or directory" is a worse
--- first impression than a pane that says plainly what it needs.
local function program()
  local named = setting("program", "")
  if type(named) ~= "string" or named:match("^%s*$") then
    return nil
  end
  return named
end

--- The argument list, as a LIST.
---
--- The multiplexer quotes each argument, so a WAD path with a space in it
--- survives being its own element and would not survive being concatenated into
--- one command line. Hence two settings rather than one: `args` is split on
--- whitespace for flags, and `wad` is appended whole.
local function args()
  local argv = {}
  local extra = setting("args", "")
  if type(extra) == "string" then
    for word in extra:gmatch("%S+") do
      argv[#argv + 1] = word
    end
  end
  -- An absolute WAD is used as given; anything else is resolved inside this plugin's
  -- own clone, which is what makes the declared default a path a reader can recognise
  -- rather than an empty box. With no interface directory published there is nowhere
  -- for a relative one to resolve against, so the argument is omitted rather than
  -- guessed — every port worth running looks for a WAD of its own, and a made-up path
  -- turns "no WAD" into "wrong WAD".
  local wad = setting("wad", PAYLOAD_WAD)
  if type(wad) ~= "string" or wad:match("^%s*$") then
    wad = PAYLOAD_WAD
  end
  if not absolute(wad) then
    wad = payload(wad)
  end
  if wad and wad ~= "" then
    argv[#argv + 1] = wad
  end
  return argv
end

--- The command line as a reader would type it. Shown before the grant is given,
--- so what you are about to trust is on screen rather than in a config file.
local function command_line()
  local shown = program()
  for _, argument in ipairs(args()) do
    shown = shown .. " " .. argument
  end
  return shown
end

-- --- capability -------------------------------------------------------------

--- Have we been trusted with `program`?
---
--- Asked rather than probed. A capability is normally withheld by ABSENCE — `run`
--- is not a function until you are trusted — but a program pane is asked for
--- through `command`, which every plugin has, so there is nothing to be absent.
--- `thurbox.granted` reports the decision instead, and grants nothing.
local function granted()
  local grants = (thurbox and thurbox.granted) or {}
  return grants.program == true
end

--- An error from the last `program` ask, if the kernel published one.
---
--- Worth drawing rather than swallowing: a program that is not on `PATH` fails
--- here, and this plugin cannot check `PATH` itself (no `io`, no `os`). The states
--- the kernel owns — nothing started yet, or the program has exited — it draws
--- inside the surface, which is where they belong.
local function ask_error()
  for _, item in ipairs((thurbox and thurbox.commands) or {}) do
    if item.kind == "program" and item.error and item.error ~= "" then
      return item.error
    end
  end
  return nil
end

-- --- chrome -----------------------------------------------------------------

local function line(spans)
  return { type = "text", len = 1, text = { spans } }
end

local function blank()
  return { type = "text", len = 1, text = "" }
end

--- The chord bound to an action now, so a rebind shows through rather than a
--- hardcoded hint going quietly wrong.
local function chord_for(action)
  for _, binding in ipairs((thurbox and thurbox.registry and thurbox.registry.keys) or {}) do
    if binding.action == action and binding.key then
      return binding.key
    end
  end
  return nil
end

--- A path or command line, in FULL, wrapped across as many rows as it needs.
---
--- Not `widgets.truncate`, which cuts the tail — and for a path the tail is the
--- filename, so an end-truncated path loses the half that identifies it and turns
--- the one string the reader has to retype into the one they cannot see. Reported
--- from a real install whose interface directory was long enough to cut the WAD's
--- name off.
---
--- `wrap` is a text-node field, so the kernel folds it; all this has to get right is
--- how many rows to ask for, since a box splits its height between children and a
--- one-row node would show one row of a three-row path. Past the cap it
--- middle-truncates, which keeps both ends: the directory says where, the leaf says
--- which one.
local function path_rows(text, width, cap)
  cap = cap or 3
  width = math.max(1, width)
  local rows = math.ceil(widgets.len(text) / width)
  if rows > cap then
    return widgets.middle_truncate(text, width * cap), cap
  end
  return text, math.max(1, rows)
end

--- A path node: the whole string, wrapped, in the accent colour.
local function path_line(text, width)
  local shown, rows = path_rows(text, width)
  return {
    type = "text",
    len = rows,
    wrap = true,
    text = { { { text = "  " .. shown, style = { fg = theme.accent } } } },
  }
end

--- A panel with a title, a body, and nothing clever.
local function panel(ctx, children)
  return {
    type = "box",
    axis = "vertical",
    frame = widgets.panel("DOOM", ctx.focused),
    children = children,
  }
end

--- What to draw before the capability has been granted.
---
--- The first thing every user of this plugin sees, so it says what would run, how
--- the grant is given, and why it is asked for separately. An empty pane here
--- reads as a broken plugin, and the fix is two keystrokes away in a modal the
--- reader may not know exists.
local function untrusted(ctx)
  local width = math.max(0, (ctx.width or 0) - 20)
  return panel(ctx, {
    blank(),
    line({
      { text = "  This pane wants to run a program you type at.", style = { fg = theme.text } },
    }),
    blank(),
    line({ { text = "  it would run", style = { fg = theme.muted } } }),
    path_line(command_line(), width),
    line({
      {
        text = "  configure `program` and `wad` in settings to run something else",
        style = { fg = theme.muted },
      },
    }),
    blank(),
    line({
      { text = "  trust it:  settings (ctrl+,) → ] → this file → ", style = { fg = theme.muted } },
      { text = "t", style = { fg = theme.hint, bold = true } },
    }),
    blank(),
    line({
      {
        text = "  Granted per file, and separately from `run`: a program that holds",
        style = { fg = theme.muted },
      },
    }),
    line({
      {
        text = "  your keystrokes is not a program you read the output of.",
        style = { fg = theme.muted },
      },
    }),
    { type = "text", fill = 1, text = "" },
  })
end

--- What to draw before a DOOM has been named.
---
--- The first thing a reader sees after installing, and the only screen that has any
--- work for them: this repository ships game DATA and no engine, so the one thing it
--- cannot know is which DOOM you want. It shows the WAD it brought, since that is the
--- argument the program will be handed.
local function needs_program(ctx)
  local width = math.max(0, (ctx.width or 0) - 6)
  -- The resolved path, not the declaration: this line exists to be read and copied.
  local wad = nil
  local argv = args()
  if #argv > 0 then
    wad = argv[#argv]
  end
  local children = {
    blank(),
    line({ { text = "  Point this pane at a terminal DOOM.", style = { fg = theme.text } } }),
    blank(),
    line({
      { text = "  settings (ctrl+, or F6) → ", style = { fg = theme.muted } },
      { text = "doom.program", style = { fg = theme.accent } },
      { text = "  — any DOOM that paints text", style = { fg = theme.muted } },
    }),
    line({
      {
        text = "  cells and reads its keys from stdin. Cells, not a graphics protocol:",
        style = { fg = theme.muted },
      },
    }),
    line({
      { text = "  a surface carries characters, so an image has nothing to parse into.", style = { fg = theme.muted } },
    }),
    blank(),
  }
  if wad then
    children[#children + 1] =
      line({ { text = "  the WAD this plugin ships, passed as the last argument:", style = { fg = theme.muted } } })
    children[#children + 1] = path_line(wad, width)
    children[#children + 1] = blank()
  end
  -- What is still missing, which is not the same question as what this panel is for.
  -- Naming a program and granting the capability are two prerequisites and either can
  -- be done first, so telling a reader who has already trusted this file to trust it
  -- reads as the pane not having noticed — which is exactly what it looked like to the
  -- person who reported it.
  if granted() then
    children[#children + 1] = line({
      { text = "  The ", style = { fg = theme.muted } },
      { text = "program", style = { fg = theme.accent } },
      { text = " capability is granted, so naming one is all that is left.", style = { fg = theme.muted } },
    })
  else
    children[#children + 1] = line({
      { text = "  Then trust it: settings → ] → this file → ", style = { fg = theme.muted } },
      { text = "t", style = { fg = theme.hint, bold = true } },
    })
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }
  return panel(ctx, children)
end

--- What to draw after the pane has been given up on purpose.
---
--- Without this there is no way back: `render` asks for the pane on every frame,
--- so a release that did not also stop the asking would be undone before the next
--- paint. The flag is the difference between "closed" and "closing".
local function released(ctx)
  local key = chord_for(RESTART) or "ctrl+alt+r"
  return panel(ctx, {
    blank(),
    line({ { text = "  DOOM released — the program was stopped.", style = { fg = theme.text } } }),
    blank(),
    widgets.hints({ { key, "start it again" } }),
    { type = "text", fill = 1, text = "" },
  })
end

--- The controls, most useful first, so trimming from the end costs least.
---
--- DOOM's own defaults, not a particular port's: this plugin ships no engine and so
--- has no business claiming one's key map. A port that rebinds them will disagree
--- with this row, which is why the README says whose keys these are.
---
--- `tab` IS here. An earlier version of this file left it out, claiming the kernel
--- reserved it for focus; that was wrong — the reserved set is `ctrl+q`, `f10`,
--- `ctrl+h`, `ctrl+l` and `f12`, and `tab` is forwarded to the focused pane on
--- purpose. The automap works.
local CONTROLS = {
  { "↑↓←→", "move" },
  { "ctrl", "fire" },
  { "space", "use" },
  { "⇧", "run" },
  { ", .", "strafe" },
  { "1-7", "weapon" },
  { "tab", "map" },
  { "esc", "menu" },
}

--- The widest prefix of `CONTROLS` that fits one row. `widgets.hints` packs
--- ` chord ` plus `label  `, so the cost is measurable before it is drawn.
local function controls_row(width)
  local shown, used = {}, 0
  for _, pair in ipairs(CONTROLS) do
    local cost = widgets.len(pair[1]) + widgets.len(pair[2]) + 4
    if used + cost > width then
      break
    end
    used = used + cost
    shown[#shown + 1] = pair
  end
  if #shown == 0 then
    return blank()
  end
  return widgets.hints(shown)
end

-- --- the pane ---------------------------------------------------------------

return {
  name = NAME,
  -- The centre, which the stock arrangement always places — so this installs and
  -- draws with no `layout.lua` edit, and `thurbox-cli plugin check` has nothing to
  -- complain about. The cost is that DOOM and the agent take turns rather than
  -- sitting side by side; a slot of its own is a two-line arrangement edit for
  -- anyone who would rather have both.
  slot = "center",
  slot_mode = "switch",
  order = 40,
  focusable = true,
  -- Keys this pane does not handle go to what its surface names. On the panels
  -- above there is no surface, so there is nothing to forward to.
  input = "session",
  capabilities = { "program" },

  -- The action band advertises this pane, which is the only way anyone finds it.
  --
  -- `center` is a SWITCH slot, so this pane is an alternate behind the agent: it
  -- draws nothing until it is focused, and a fresh install therefore looks like an
  -- install that did nothing. The agent pane's own border strip cannot help — it
  -- hardcodes its two views and is a file the user owns — but the band is kernel
  -- chrome and takes a declared entry. Low priority: a game should be the first
  -- thing dropped when the band runs out of width.
  pills = {
    { action = OPEN, label = "DOOM", priority = 10 },
  },

  keys = {
    -- Global, so it works from wherever the reader is standing rather than only
    -- from a pane they cannot see yet. An F-key rather than a chord because a
    -- focused terminal keeps bare `ctrl+<letter>` for the program in it.
    {
      key = "f7",
      action = OPEN,
      desc = "show the DOOM pane",
      scope = "global",
      group = "DOOM",
    },
    -- Plugin-scoped, so they fire only while this pane has focus. `ctrl+alt+`
    -- because a declared chord is consumed before the surface sees it, and DOOM
    -- wants every bare key there is — including the letters, for cheats.
    {
      key = "ctrl+alt+r",
      action = RESTART,
      desc = "restart DOOM in this pane",
      group = "DOOM",
    },
    {
      key = "ctrl+alt+x",
      action = RELEASE,
      desc = "stop DOOM and give up the pane",
      group = "DOOM",
    },
  },

  settings = {
    -- `program` has no default worth guessing, so the pane says so until it is set.
    -- `wad` does: empty means the one this repository brought with it.
    {
      id = "program",
      desc = "The terminal DOOM to run. Required: this plugin ships a WAD, not an engine",
      default = "",
    },
    {
      id = "wad",
      desc = "WAD, passed as the last argument. A relative path resolves inside this plugin's clone",
      default = PAYLOAD_WAD,
    },
    {
      id = "args",
      desc = "Extra arguments, split on spaces (a path with spaces belongs in the WAD setting)",
      default = "",
    },
    {
      id = "footer",
      desc = "Show the controls row under the game",
      default = true,
    },
  },

  render = function(ctx)
    -- Before the grant is relevant: with no program named there is nothing to grant
    -- a capability FOR, and asking for one would be refused as a plugin error. So
    -- configuration comes first, and it is one setting.
    if not program() then
      return needs_program(ctx)
    end
    if not granted() then
      return untrusted(ctx)
    end
    if state.released then
      return released(ctx)
    end

    -- Every frame, deliberately. Asking for a pane that exists is a map lookup
    -- rather than a second copy of the program, so there is no clever place to
    -- start it once — and a pane that only asked on a keypress would come back
    -- empty after a reload.
    -- `program()` cannot be nil here: the branch above returned when it was.
    command("program", { text = PANE, repo = program(), args = args() })

    local failed = ask_error()
    local children = {
      -- The kernel fills this from the pane's own parser, and draws the states it
      -- owns: nothing behind it yet, or the program has exited. A frozen grid
      -- would look exactly like a live one, so it says which.
      { type = "surface", program = PANE, fill = 1 },
    }
    if failed then
      children[#children + 1] = line({
        {
          -- Middle-truncated, not end-truncated: a failure names a path, and the
          -- leaf is the half that says which one. One row, because it sits under
          -- the game and wrapping it would cost rows the game is using.
          text = " " .. widgets.middle_truncate(failed, math.max(0, (ctx.width or 0) - 3)),
          style = { fg = theme.bad },
        },
      })
    elseif setting("footer", true) ~= false then
      children[#children + 1] = controls_row(math.max(0, (ctx.width or 0) - 2))
    end

    return panel(ctx, children)
  end,

  on_action = function(action)
    if action == OPEN then
      -- In a switch slot, focusing IS what brings the view forward.
      command("focus", { text = NAME })
      return true
    end
    if action == RELEASE then
      -- Stopped on purpose rather than left running unseen. The flag is what stops
      -- `render` asking for it straight back.
      command("program", { text = PANE, action = "close" })
      state.released = true
      return true
    end
    if action == RESTART then
      -- Close, then let the next frame's ask start it afresh. Also the way back
      -- from a program that exited on its own: Lua cannot see that state, so this
      -- is how you act on what the kernel drew.
      command("program", { text = PANE, action = "close" })
      state.released = nil
      return true
    end
    return false
  end,
}
