-- Binds, mirroring modules/desktop/niri/binds.nix.

local fp = require("fp.data")
local columns = require("fp.columns")
local projects = require("fp.projects")
local util = require("fp.util")
local mod, sh_quote, run = util.mod, util.sh_quote, util.run

local function dms(args)
    return hl.dsp.exec_cmd("dms ipc " .. args)
end

-- Media and brightness keys work on the lock screen too.
for _, b in ipairs({
    { "XF86AudioRaiseVolume", "audio increment 3" },
    { "XF86AudioLowerVolume", "audio decrement 3" },
    { "XF86AudioMute", "audio mute" },
    { "XF86AudioMicMute", "audio micmute" },
    { "XF86MonBrightnessUp", [[brightness increment 5 ""]] },
    { "XF86MonBrightnessDown", [[brightness decrement 5 ""]] },
    { "XF86AudioPlay", "mpris playPause" },
    { "XF86AudioPause", "mpris playPause" },
    { "XF86AudioNext", "mpris next" },
    { "XF86AudioPrev", "mpris previous" },
    { "XF86AudioStop", "mpris stop" },
}) do
    hl.bind(b[1], dms(b[2]), { locked = true })
end

for _, b in ipairs({
    { "N", "notifications toggle", "Toggle Notification Center" },
    { "V", "clipboard toggle", "Toggle Clipboard Manager" },
    { "space", "spotlight toggle", "Toggle Application Launcher" },
    { "semicolon", 'spotlight toggleQuery ":"', "Toggle Emoji Picker" },
    { "P", "powermenu toggle", "Toggle Power Menu" },
    { "B", fp.dms_b, "Toggle Agent Hub / Dashboard" },
    { "SHIFT + N", "notepad toggle", "Toggle Notepad" },
    { "SHIFT + comma", "settings focusOrToggle", "Toggle DMS Settings" },
    { "SHIFT + Escape", "processlist focusOrToggle", "Toggle Process List" },
    { "SHIFT + I", "inhibit toggle", "Toggle Keep-Awake (Idle Inhibit)" },
    { "ALT + L", "lock lock", "Lock Screen" },
    { "CTRL + N", "notifications toggleDoNotDisturb", "Toggle Do Not Disturb" },
    { "SHIFT + P", "color-picker toggle", "Toggle Color Picker" },
    -- DMS's own overview and bind cheatsheet; Hyprland has neither built in.
    { "A", "hypr toggleOverview", "Toggle Overview" },
    { "slash", "hypr toggleBinds", "Show Keybinds" },
}) do
    hl.bind(mod .. " + " .. b[1], dms(b[2]), { description = b[3] })
end

if fp.bin.agent_hub then
    for _, b in ipairs({
        { "SHIFT + B", "focus-next", "Focus the Next Agent That Wants You" },
        { "ALT + B", "show --toggle", "Toggle the Focused Agent's Notes" },
        { "CTRL + B", "toggle", "Dismiss or Bring Back the Focused Agent's Turn" },
    }) do
        hl.bind(mod .. " + " .. b[1], hl.dsp.exec_cmd(fp.bin.agent_hub .. " " .. b[2]), { description = b[3] })
    end
end

hl.bind(mod .. " + D", hl.dsp.submap("fp-switch"), { description = "Switch to project workspace" })
hl.bind(mod .. " + SHIFT + D", hl.dsp.submap("fp-move"), { description = "Move window to project workspace" })
hl.bind(mod .. " + CTRL + D", hl.dsp.submap("fp-close"), { description = "Close a project workspace" })

-- Focus: across columns, then across monitors at the strip's edge.
for _, b in ipairs({ { "left", "H", "l" }, { "right", "L", "r" }, { "up", "K", "u" }, { "down", "J", "d" } }) do
    local arrow, vim, dir = b[1], b[2], b[3]
    for _, key in ipairs({ arrow, vim }) do
        if dir == "l" or dir == "r" then
            hl.bind(mod .. " + " .. key, hl.dsp.focus({ direction = dir }))
        else
            hl.bind(mod .. " + " .. key, function()
                columns.focus_vertical(dir)
            end)
        end
        hl.bind(mod .. " + CTRL + " .. key, hl.dsp.focus({ monitor = dir }))
        if dir == "l" or dir == "r" then
            hl.bind(mod .. " + SHIFT + " .. key, function()
                columns.move_column(dir)
            end)
        else
            hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ direction = dir }))
        end
    end
end

hl.bind(mod .. " + Home", function()
    columns.focus_column("first")
end)
hl.bind(mod .. " + End", function()
    columns.focus_column("last")
end)
hl.bind(mod .. " + SHIFT + Home", function()
    columns.move_column_to("first")
end)
hl.bind(mod .. " + SHIFT + End", function()
    columns.move_column_to("last")
end)

hl.bind(mod .. " + F", columns.maximize_column)
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
-- niri's tabbed column is a Hyprland group: one tile holding several windows behind a tab bar.
hl.bind(mod .. " + M", columns.toggle_tabbed)
hl.bind(mod .. " + S", hl.dsp.window.float())
hl.bind(mod .. " + C", hl.dsp.layout("colresize +conf"))
hl.bind(mod .. " + X", hl.dsp.layout("colresize +0.05"))
hl.bind(mod .. " + SHIFT + X", hl.dsp.layout("colresize -0.05"))
hl.bind(mod .. " + CTRL + X", hl.dsp.layout("fit expand"))
hl.bind(mod .. " + Z", function()
    columns.grow_height(0.05)
end)
hl.bind(mod .. " + SHIFT + Z", function()
    columns.grow_height(-0.05)
end)
hl.bind(mod .. " + comma", hl.dsp.layout("consume_or_expel prev"))
hl.bind(mod .. " + period", hl.dsp.layout("consume_or_expel next"))

hl.bind(mod .. " + mouse_down", hl.dsp.layout("focus r"))
hl.bind(mod .. " + mouse_up", hl.dsp.layout("focus l"))
hl.bind(mod .. " + mouse_right", hl.dsp.layout("focus r"))
hl.bind(mod .. " + mouse_left", hl.dsp.layout("focus l"))
hl.bind(mod .. " + SHIFT + mouse_down", function()
    columns.focus_workspace(1)
end)
hl.bind(mod .. " + SHIFT + mouse_up", function()
    columns.focus_workspace(-1)
end)
hl.bind(mod .. " + SHIFT + mouse_right", hl.dsp.layout("swapcol r"))
hl.bind(mod .. " + SHIFT + mouse_left", hl.dsp.layout("swapcol l"))
-- Built into niri: Mod+drag moves a window, Mod+right-drag resizes it.
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Screenshots: region, focused output and focused window to the clipboard; Mod+Print annotates.
local function grab(geometry)
    run(fp.bin.grim .. " " .. geometry .. " - | " .. fp.bin.wl_copy)
end
hl.bind("Print", function()
    grab('-g "$(' .. fp.bin.slurp .. ')"')
end)
hl.bind("CTRL + Print", function()
    local m = hl.get_active_monitor()
    if m then
        grab("-o " .. sh_quote(m.name))
    end
end)
hl.bind("ALT + Print", function()
    local w = hl.get_active_window()
    if w then
        grab(string.format('-g "%d,%d %dx%d"', w.at.x, w.at.y, w.size.x, w.size.y))
    end
end)
hl.bind(mod .. " + Print", hl.dsp.exec_cmd("screenshot"), { description = "Screenshot region (annotate in satty)" })

hl.bind(mod .. " + Return", function()
    projects.terminal(false)
end, { description = "Terminal in the working directory" })
hl.bind(mod .. " + SHIFT + Return", function()
    projects.terminal(true)
end, { description = "Terminal stacked in the focused column" })
hl.bind(mod .. " + BackSpace", hl.dsp.window.close())
-- window-kill's job, natively; X11 windows carry their own pid with the built-in Xwayland.
hl.bind(mod .. " + SHIFT + BackSpace", hl.dsp.window.kill(), { description = "Force-kill focused window (SIGKILL)" })
