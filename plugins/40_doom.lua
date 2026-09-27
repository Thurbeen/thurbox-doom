-- Settings provider for the Doom tab in thurbox-code-review's agent pane.
-- The program and its WAD stay in this package's clone.
return {
  name = "doom",
  slot = "center",
  slot_mode = "switch",
  order = 40,
  focusable = false,
  render = function()
    return { type = "text", fill = 1, text = "" }
  end,
  settings = {
    { id = "program", desc = "Terminal DOOM to run. Empty selects the bundled linux-x86_64 engine", default = "" },
    {
      id = "wad",
      desc = "WAD, passed as the last argument. A relative path resolves inside this plugin's clone",
      default = "wad/doom1.wad",
    },
    {
      id = "args",
      desc = "Arguments before the WAD, split on spaces. The shipped engine needs -iwad",
      default = "-iwad",
    },
    { id = "footer", desc = "Show the controls row under the game", default = true },
  },
}
