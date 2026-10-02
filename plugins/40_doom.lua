-- Keep standalone Doom available without the companion agent pane.
-- With the companion installed, the pane only supplies settings and a pill
-- that invokes the agent pane's F5 action.
local doom = require("thurbox-doom.lib.doom")
local integrated = pcall(require, "thurbox-code-review.lib.review")

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
