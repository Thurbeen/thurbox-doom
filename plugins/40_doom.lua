-- Compatibility pane that declares Doom's settings without a focus stop.
-- The agent pane imports the same module for rendering and program control.
local doom = require("thurbox-doom.lib.doom")
return {
  name = "doom",
  slot = "center",
  slot_mode = "switch",
  order = 40,
  focusable = false,
  settings = doom.settings,
  render = function()
    return { type = "text", fill = 1, text = "" }
  end,
}
