-- DOOM, as a thurbox session.
--
-- The pane places and frames a live PTY `surface`, decides which session it
-- shows, and owns the key rules; the kernel only fills the rect with cells.
-- That division of labour is `20_agent.lua`'s, and this file is deliberately
-- the same shape: what is different is only WHICH session it frames and what it
-- draws when there is none.
--
-- So the thing running DOOM is not this plugin. It is a native terminal DOOM
-- port, launched by the kernel as an ordinary session's process, parsed by the
-- kernel's vt100 parser, and painted into the rect this file asks for. Nothing
-- here needs `capabilities`: no `run`, so no trust gate, because a session is
-- something the kernel already owns.
--
-- WHAT THIS IS NOT. It is not a software renderer. A Lua half-block rasteriser
-- is expressible — `surface` takes Lua-supplied styled runs and `parse_color`
-- accepts `#rrggbb` — but there is no way to get frames into Lua: no WASM
-- runtime, no ffi, no filesystem, and `run` completes rather than streams. A
-- DOOM frame is also thousands of styled runs — ~4000 at 80x50 drawn cell by
-- cell, and ~2300 colour spans even as `doom-ascii`'s own run-length-coded
-- output measures — against a style-conversion path whose hottest measured case
-- is ~100 spans a pane. The PTY route costs none of that: the cells never pass
-- through Lua at all.
--
-- Two render states, and the first one matters more than it looks: a launcher
-- panel is what every user of this plugin sees first, and it is the only place
-- a failed launch can explain itself.

local theme = require("lib.theme")
local widgets = require("lib.widgets")

--- What this pane is called. Declared once because it has to name ITSELF to
--- bring itself forward (`command("focus", …)`), exactly as `20_agent.lua` does.
local NAME = "doom"

--- The `agents.toml` entry a DOOM session is launched with, and the mark by
--- which this pane recognises one.
---
--- A constant rather than a setting: it is the contract the README's
--- `[[agents]]` snippet writes, and it is how a session created a moment ago is
--- found again. `command("create")` returns nothing and the session appears in a
--- LATER snapshot with an id this pane never saw, so the agent name is the only
--- durable handle on "the DOOM session".
local AGENT = "doom"

--- The directory `command("create")` is given as its `repo`.
---
--- `repo` is required (`src/kernel/command.rs`: `command "create" needs a repo`)
--- and DOOM does not care about one, so this is a deliberate choice rather than
--- a meaningful value. A `~` is expanded by the kernel for a local session
--- (`command.rs` calls `paths::expand_tilde` before touching it), and the only
--- check it makes is `is_dir` — no branch is passed, so no worktree is cut and
--- nothing needs the directory to be a git repository.
local DEFAULT_DIR = "~"

--- The name the session is created with, so the session list shows something
--- recognisable rather than the directory's basename.
local SESSION_NAME = "doom"

local LAUNCH = "doom.launch"

-- --- settings ---------------------------------------------------------------
--
-- Both are DECLARED as data at the bottom of this file, which is what puts them
-- in the settings modal. These two functions are the read side.

--- A declared boolean setting.
---
--- `lib.settings.enabled(plugin, id, default)` is the confirmed reader — it is
--- what the bundled session list and the `plugin new` starter both use.
local function setting_flag(id, default)
  local ok, settings = pcall(require, "lib.settings")
  if not ok or type(settings) ~= "table" or type(settings.enabled) ~= "function" then
    return default
  end
  local got, value = pcall(settings.enabled, NAME, id, default)
  if got and type(value) == "boolean" then
    return value
  end
  return default
end

--- A declared STRING setting, or `fallback`.
---
--- Deliberately defensive. Only the boolean reader above is confirmed to exist,
--- so a string-valued setting is *probed*: whichever of the plausible readers
--- `lib.settings` turns out to expose is used, and when none of them is there
--- the declared default applies. The worst case is therefore a pane that
--- launches DOOM in `DEFAULT_DIR` and a settings row that does not take effect
--- — never a pane that throws on a nil call.
local function setting_string(id, fallback)
  local ok, settings = pcall(require, "lib.settings")
  if ok and type(settings) == "table" then
    for _, reader in ipairs({ "value", "get", "string" }) do
      if type(settings[reader]) == "function" then
        local got, value = pcall(settings[reader], NAME, id, fallback)
        if got and type(value) == "string" and value ~= "" then
          return value
        end
      end
    end
  end
  return fallback
end

-- --- the session ------------------------------------------------------------
--
-- `state` holds only FLAT SCALARS here, on purpose: reading `state` hands back a
-- copy, so a nested table mutated in place is silently the old value on the next
-- frame. Nothing below has a nested field to lose.

--- The DOOM session, resolved against the CURRENT snapshot.
---
--- The remembered id is a hint, never the answer. A session the user deleted has
--- to stop being framed — a `surface` naming a dead id is the one failure this
--- pane can cause on its own — so the id is looked up every time and dropped
--- when the snapshot no longer has it.
---
--- Falling back to "any session whose agent is `doom`" is not a nicety either:
--- it is how a launch is ever picked up. `command("create")` never returns an
--- id, so the session this pane asked for arrives in a later snapshot as a
--- stranger, and its agent name is what identifies it.
---
--- A FUNCTION rather than a field, because what a key acts on must be what was
--- on screen — a value derived while drawing is not visible to `on_key`.
local function doom_session()
  local sessions = (thurbox and thurbox.sessions) or {}
  local remembered = state.session
  if remembered then
    for _, session in ipairs(sessions) do
      if session.id == remembered then
        return session
      end
    end
  end
  for _, session in ipairs(sessions) do
    if session.agent == AGENT then
      return session
    end
  end
  return nil
end

--- Is the `doom` agent registered in `agents.toml`?
---
--- Three answers, and the third is the honest one: `true`, `false`, or `nil` for
--- "cannot tell". The row shape of `thurbox.agents` is not something this file
--- can verify, so an entry is read as a table with a `name` or as a bare string,
--- and anything else reports unknown rather than guessing wrong — telling a user
--- their agent is missing when it is not would send them editing a correct file.
local function agent_registered()
  local agents = thurbox and thurbox.agents
  if type(agents) ~= "table" then
    return nil
  end
  local saw_any = false
  for _, entry in ipairs(agents) do
    local name = nil
    if type(entry) == "table" then
      name = entry.name
    elseif type(entry) == "string" then
      name = entry
    end
    if type(name) == "string" then
      saw_any = true
      if name == AGENT then
        return true
      end
    end
  end
  if saw_any then
    return false
  end
  return nil
end

--- The error from a launch that failed.
---
--- Commands never block and never return a result, so this is the only place a
--- failed `create` is visible: `thurbox.commands` carries it as `item.error`
--- while the command is still in flight. Swallowing it would leave the pane
--- looking like the key did nothing — and this is exactly how a user finds out
--- that the `doom` agent is not registered or that the binary is not on `PATH`,
--- neither of which this plugin can check itself (no `io`, no `os`).
---
--- The live error is preferred, with the last one latched in `state` behind it,
--- because an in-flight command leaves the queue and the message would otherwise
--- vanish a frame after it appeared.
local function launch_error()
  for _, item in ipairs((thurbox and thurbox.commands) or {}) do
    if item.kind == "create" and item.error and item.error ~= "" then
      return item.error, true
    end
  end
  local latched = state.error
  if type(latched) == "string" and latched ~= "" then
    return latched, false
  end
  return nil, false
end

-- --- chrome -----------------------------------------------------------------

--- The chord bound to an action right now, so a rebind is reflected rather than
--- hardcoded. `thurbox.registry.keys` is what the help modal renders from.
local function chord_for(action)
  for _, binding in ipairs((thurbox and thurbox.registry and thurbox.registry.keys) or {}) do
    if binding.action == action and binding.key then
      return binding.key
    end
  end
  return nil
end

--- One row of styled spans.
local function line(spans)
  return { type = "text", len = 1, text = { spans } }
end

local function blank()
  return { type = "text", len = 1, text = "" }
end

--- A requirement row: a state glyph, what it is, and how it is checked.
---
--- `nil` state is drawn as a question rather than as a failure. Two of the three
--- requirements are genuinely uncheckable from inside the sandbox, and saying so
--- is more useful than a red cross that means "I did not look".
local function requirement(ok, label, note, width)
  local glyph, glyph_style
  if ok == true then
    glyph, glyph_style = "✓", { fg = theme.ok }
  elseif ok == false then
    glyph, glyph_style = "✗", { fg = theme.bad }
  else
    glyph, glyph_style = "?", { fg = theme.muted }
  end
  local spans = {
    { text = "  " },
    { text = glyph, style = glyph_style },
    { text = " " .. label, style = { fg = theme.text } },
  }
  local room = width - 5 - widgets.len(label)
  if note and room > 4 then
    spans[#spans + 1] = { text = "  " .. widgets.truncate(note, room), style = { fg = theme.muted } }
  end
  return line(spans)
end

--- The launcher panel: what this is, what it needs, the key that starts it, and
--- whatever the last attempt had to say.
local function launcher(ctx)
  local width = math.max(0, (ctx.width or 0) - 2)
  local key = chord_for(LAUNCH) or "p"
  local children = {
    blank(),
    line({ { text = "  DOOM runs here as a thurbox session.", style = { fg = theme.text } } }),
    line({
      {
        text = "  A native terminal port is the session's process; this pane frames it.",
        style = { fg = theme.muted },
      },
    }),
    blank(),
    line({ { text = "  Needs", style = { fg = theme.accent, bold = true } } }),
    requirement(agent_registered(), "a `doom` agent in agents.toml", "read from the snapshot", width),
    requirement(nil, "a terminal DOOM port on PATH", "the agent's command; not checkable here", width),
    requirement(nil, "a WAD", "passed by the agent's args, e.g. -iwad", width),
    blank(),
    widgets.divider(width, "─"),
    blank(),
  }

  local message, live = launch_error()
  if message then
    children[#children + 1] = line({
      { text = "  launch failed", style = { fg = theme.bad, bold = true } },
      { text = live and "" or "  (last attempt)", style = { fg = theme.muted } },
    })
    children[#children + 1] = line({
      { text = "  " .. widgets.truncate(message, math.max(0, width - 2)), style = { fg = theme.bad } },
    })
    children[#children + 1] = blank()
  end

  children[#children + 1] = widgets.hints({ { key, "launch DOOM" } })
  children[#children + 1] = { type = "text", fill = 1, text = "" }

  return {
    type = "box",
    axis = "vertical",
    frame = widgets.panel("DOOM", ctx.focused),
    children = children,
  }
end

--- The controls DOOM answers to, most important first.
---
--- Ordered so that dropping from the end to make it fit takes the least useful
--- hint away first. `tab` is absent deliberately: it is the automap, and the
--- kernel reserves `tab` for focus, so it never reaches the game.
local CONTROLS = {
  { "↑↓←→", "move" },
  { "space", "fire" },
  { ", .", "strafe" },
  { "e", "use" },
  { "]", "run" },
  { "1-7", "weapon" },
  { "esc", "menu" },
}

--- The widest prefix of `CONTROLS` that fits, as one hint row.
---
--- `widgets.hints` packs ` chord ` plus `label  ` per pair, so the width is
--- measurable before it is drawn — which is what lets this drop hints rather
--- than overflow the row.
local function controls_row(width)
  local shown = {}
  local used = 0
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
  slot = "center",
  -- One occupant of the centre is visible at a time, and focusing this pane is
  -- what brings it forward — which is why the launch action focuses itself.
  slot_mode = "switch",
  -- Keys this plugin does not handle go straight to the pty. That is what makes
  -- DOOM playable at all: the game reads the same keystrokes it would read in a
  -- bare terminal, and this file spends no code forwarding them.
  input = "session",
  -- After the agent pane (20), so the centre still opens on the agent.
  order = 40,
  focusable = true,

  -- No `capabilities`. Nothing here runs a program: the DOOM process is a
  -- session, which the kernel owns, so there is no trust gate to fail and no
  -- "untrusted" state to draw.

  keys = {
    -- Plugin-scoped, so it fires only while this pane has focus — which is what
    -- a launch key wants, and it leaves `p` free everywhere else.
    --
    -- `p` because vanilla DOOM binds nothing to it (verified against
    -- `doom-ascii`'s `.default.cfg`: strafe `,`/`.`, use `e`, speed `]`, fire
    -- space). A declared chord is consumed before `input = "session"` forwards
    -- anything, so a key the game wants would be a key the game never sees.
    {
      key = "p",
      action = LAUNCH,
      desc = "launch DOOM as a session",
      group = "DOOM",
    },
  },

  settings = {
    {
      id = "dir",
      desc = "Directory the DOOM session is created in (`create` requires a repo)",
      default = DEFAULT_DIR,
    },
    {
      id = "footer",
      desc = "Show the controls row under the game",
      default = true,
    },
  },

  render = function(ctx)
    local session = doom_session()

    -- Reconcile the remembered id with what the snapshot actually has: adopt the
    -- session that was found, and forget one that is gone. Nothing depends on
    -- this write landing — every reader calls `doom_session()` — so a persisted
    -- id is a convenience across a reload, not the mechanism.
    --
    -- WRITING `state` FROM `render` IS BEHAVIOUR THE DOCS DISCLAIM. `docs/
    -- PLUGINS.md` says flatly that "`render` does not write `state`". It does
    -- today: `kernel::host`'s `install_private` gives `state` a `__newindex`
    -- that writes straight into the shared per-plugin map, and the render path
    -- enters, calls and converts with no state swap and no rollback — so the
    -- write lands. The bundled session list relies on the same thing for its
    -- cursor.
    --
    -- Only the error latch below depends on it. If the kernel is ever changed
    -- to match its own documentation, that latch dies SILENTLY — a failed
    -- launch would then be shown only while its command is still in flight —
    -- and nothing else about this pane changes.
    state.session = session and session.id or nil
    if session then
      state.error = nil
    else
      local message = launch_error()
      state.error = message
    end

    if not session then
      return launcher(ctx)
    end

    -- A dead pane explains itself rather than framing nothing.
    if session.attach_error then
      return {
        type = "box",
        axis = "vertical",
        frame = widgets.panel("DOOM", ctx.focused),
        children = {
          line({ { text = "  no live terminal", style = { fg = theme.bad, bold = true } } }),
          line({ { text = "  " .. session.attach_error, style = { fg = theme.muted } } }),
          { type = "text", fill = 1, text = "" },
        },
      }
    end

    local children = {
      -- The kernel fills this with cells from the session's own vt100 parser.
      -- Lua supplies the rect and nothing else.
      { type = "surface", session = session.id, fill = 1 },
    }
    -- The footer costs the game a row, so it is a setting rather than a fact.
    if setting_flag("footer", true) then
      children[#children + 1] = controls_row(math.max(0, (ctx.width or 0) - 2))
    end

    return {
      type = "box",
      axis = "vertical",
      frame = widgets.panel("DOOM", ctx.focused),
      children = children,
    }
  end,

  -- The keystroke itself is not needed: this handler's whole job is to decide
  -- whether the pty gets it, and that turns only on whether the game is running.
  on_key = function(_key)
    if doom_session() then
      -- The game is on screen: everything this pane did not declare belongs to
      -- it.
      return false
    end
    -- No session, so there is no pty of ours to forward to — and `input =
    -- "session"` would hand the keystroke to whichever session the kernel
    -- resolves, which on the launcher screen means typing into somebody else's
    -- agent. Swallow it instead.
    --
    -- Swallowing everything is safe here, and nothing needs excepting from it.
    -- A DECLARED chord is resolved to its action before this handler is
    -- consulted — this pane's launch key, help, settings, the theme picker —
    -- so returning `true` cannot shadow a binding; and the reserved chords
    -- (`ctrl+q`, `f10`, `tab`, `shift+tab`, `ctrl+h`/`ctrl+l`, `f12`) never
    -- reach a plugin at all, so it cannot trap anyone either. `on_key` is only
    -- reached by keystrokes no binding claimed.
    return true
  end,

  on_action = function(action)
    if action ~= LAUNCH then
      return false
    end
    local session = doom_session()
    if session then
      -- Already running: bring it forward rather than starting a second one.
      command("focus", { text = NAME })
      return true
    end
    -- `repo` is required and unused by DOOM; no `branch`, so no worktree is cut.
    -- The agent name is the contract with `agents.toml` — and the handle by
    -- which the session this creates is recognised in a later snapshot.
    command("create", {
      repo = setting_string("dir", DEFAULT_DIR),
      text = SESSION_NAME,
      agent = AGENT,
    })
    command("focus", { text = NAME })
    return true
  end,
}
