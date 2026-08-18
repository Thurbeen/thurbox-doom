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
--- REPOSITORY's name, not the plugin's, and everything the repo holds arrives with
--- it:
---
---     <interface dir>/thurbox-doom/bin/doom            the launcher, executable
---     <interface dir>/thurbox-doom/wad/freedoom1.wad   the WAD
---
--- Which is what makes this pane need no configuration at all after an install.
local CLONE_DIR = "thurbox-doom"
local PAYLOAD_PROGRAM = "bin/doom"
local PAYLOAD_WAD = "wad/freedoom1.wad"

--- The port to fall back to when the interface directory is unknown: a name, so
--- `PATH` answers it.
local FALLBACK_PROGRAM = "pi-doom"

--- A path inside this repository's working copy, or nil when the kernel has not
--- published where the interface lives.
---
--- Absolute on purpose. A program pane has no session and therefore no repository,
--- so the kernel runs it in the interface directory — a relative path would happen
--- to work today and break the day that changes.
local function payload(name)
  local dir = thurbox and thurbox.ui_dir
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return (dir:gsub("[/\\]+$", "")) .. "/" .. CLONE_DIR .. "/" .. name
end

--- Is there anything here for this machine?
---
--- `thurbox.platform` is the kernel's answer to platform selection: it publishes
--- `os` and `arch` and models nothing, so each plugin states the rule it actually
--- needs. Mine is narrow and honest — the launcher is a POSIX shell script, so on
--- Windows it says so rather than failing to exec and leaving the reader to guess.
--- A user with their own engine can still set `program` and be right.
local function unsupported_os()
  local platform = (thurbox and thurbox.platform) or {}
  if platform.os == "windows" then
    return "windows"
  end
  return nil
end

local RESTART, RELEASE = "doom.restart", "doom.release"

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

--- The program to run: what you configured, else the delivered copy, else `PATH`.
local function program()
  local named = setting("program", "")
  if type(named) == "string" and not named:match("^%s*$") then
    return named
  end
  return payload(PAYLOAD_PROGRAM) or FALLBACK_PROGRAM
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
  -- Unset means the delivered WAD, if there is anywhere for one to have been
  -- delivered to. Failing that, nothing: every port worth running looks for a WAD
  -- of its own, and a made-up path would turn "no WAD" into "wrong WAD".
  local wad = setting("wad", "")
  if type(wad) ~= "string" or wad == "" then
    wad = payload(PAYLOAD_WAD)
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
    line({
      { text = "  it would run  ", style = { fg = theme.muted } },
      { text = widgets.truncate(command_line(), width), style = { fg = theme.accent } },
    }),
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

--- What to draw on a machine this plugin has nothing for.
---
--- Politely, and with the way out: the launcher shipped here is a POSIX shell
--- script, but the pane itself is indifferent — point `program` at any terminal
--- DOOM that paints text cells and it will frame it.
local function unsupported(ctx, os_name)
  return panel(ctx, {
    blank(),
    line({
      { text = "  Nothing here runs on ", style = { fg = theme.text } },
      { text = os_name, style = { fg = theme.accent } },
      { text = " yet.", style = { fg = theme.text } },
    }),
    blank(),
    line({
      {
        text = "  The launcher this plugin ships is a POSIX shell script. Set the",
        style = { fg = theme.muted },
      },
    }),
    line({
      {
        text = "  `program` setting to a terminal DOOM of your own and this pane",
        style = { fg = theme.muted },
      },
    }),
    line({ { text = "  will frame it just the same.", style = { fg = theme.muted } } }),
    { type = "text", fill = 1, text = "" },
  })
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
--- `tab` IS here. An earlier version of this file left it out, claiming the kernel
--- reserved it for focus; that was wrong — the reserved set is `ctrl+q`, `f10`,
--- `ctrl+h`, `ctrl+l` and `f12`, and `tab` is forwarded to the focused pane on
--- purpose. The automap works. `q` is here because quitting the game leaves an
--- exited pane rather than closing this one.
local CONTROLS = {
  { "wasd/↑↓←→", "move" },
  { "f", "fire" },
  { "space", "use" },
  { "⇧wasd", "run" },
  { "1-7", "weapon" },
  { "tab", "map" },
  { "esc", "menu" },
  { "q", "quit game" },
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

  keys = {
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
    -- Both empty by default, and empty MEANS something: the copy in this
    -- package's own directory beside the panes. Set either to override it.
    {
      id = "program",
      desc = "Program to run. Empty = the launcher in this plugin's own clone, else PATH",
      default = "",
    },
    {
      id = "wad",
      desc = "WAD, passed as the last argument. Empty = the one in this plugin's own clone",
      default = "",
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
    -- Before the grant is even relevant: nothing to start here is worse than
    -- untrusted, and asking for a program that cannot exec would report a failure
    -- that reads like a bug in the pane. Skipped when `program` is set, since then
    -- the launcher shipped here is not what would run.
    local elsewhere = setting("program", "")
    local unusable = unsupported_os()
    if unusable and (type(elsewhere) ~= "string" or elsewhere:match("^%s*$")) then
      return unsupported(ctx, unusable)
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
          text = " " .. widgets.truncate(failed, math.max(0, (ctx.width or 0) - 3)),
          style = { fg = theme.bad },
        },
      })
    elseif setting("footer", true) ~= false then
      children[#children + 1] = controls_row(math.max(0, (ctx.width or 0) - 2))
    end

    return panel(ctx, children)
  end,

  on_action = function(action)
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
