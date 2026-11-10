-- niri's overview, from the hyprland-scroll-overview plugin.

local fp = require("fp.data")
local mod = require("fp.util").mod

hl.plugin.load(fp.plugins.scrolloverview)

hl.config({
    plugin = {
        scrolloverview = {
            -- niri's overview.zoom.
            scale = 0.45,
            workspace_gap = 60,
            layout = "vertical",
            -- Each workspace as a card with the wallpaper on niri's flat backdrop.
            wallpaper = 1,
            shadow = { enabled = true },
            cross_monitor_drag = true,
        },
    },
})

hl.bind(mod .. " + A", function()
    hl.plugin.scrolloverview.overview("toggle all")
end, { description = "Toggle Overview" })
