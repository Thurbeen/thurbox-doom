-- Keep standalone Doom available unless the agent pane has a Doom tab.
-- With that tab, the pane only supplies settings and a pill that invokes the
-- agent pane's F5 action.
local doom = require("thurbox-doom.lib.doom")

-- The tab is there when the agent pane itself declares "doom.open"; the
-- code-review plugin alone is not enough, since its main has no Doom tab.
local function agent_has_doom_tab()
  local ok, agent = pcall(require, "thurbox-code-review.plugins.20_agent")
  if not ok or type(agent) ~= "table" then
    return false
  end
  for _, key in ipairs(agent.keys or {}) do
    if key.action == "doom.open" then
      return true
    end
  end
  return false
end

local integrated = agent_has_doom_tab()

local pane = {
  name = "doom",
  slot = "center",
  slot_mode = "switch",
  order = 40,
  settings = doom.settings,
  pills = { { action = "doom.open", label = "Doom", priority = 10 } },
}

if integrated then
  pane.focusable = false
  pane.render = function()
    return { type = "text", fill = 1, text = "" }
  end
else
  pane.focusable = true
  pane.input = "session"
  pane.capabilities = { "program" }
  pane.keys = {
    { key = "f5", action = "doom.open", desc = "toggle Doom", scope = "global", group = "DOOM" },
    { key = "ctrl+alt+r", action = "doom.restart", desc = "restart Doom", group = "DOOM" },
    { key = "ctrl+alt+x", action = "doom.release", desc = "stop Doom", group = "DOOM" },
  }
  pane.render = doom.render
  pane.on_action = function(action)
    if action == "doom.open" then
      command("focus", { text = "doom", toggle = true })
      return true
    end
    return doom.on_action(action)
  end
end

return pane
