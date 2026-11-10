-- Outputs, environment, look and window rules.

local fp = require("fp.data")
local columns = require("fp.columns")
local rgb = require("fp.util").rgb

for _, m in ipairs(fp.monitors) do
    if m.enable then
        hl.monitor({
            output = m.name,
            mode = m.mode,
            position = m.position,
            scale = m.scale,
            transform = m.transform,
            -- 3: only while a fullscreen window has game/video content, the nearest to niri's
            -- per-window on-demand VRR (see the content rules below).
            vrr = m.vrr and 3 or 0,
        })
    else
        hl.monitor({ output = m.name, disabled = true })
    end
end

hl.env("NIXOS_OZONE_WL", "1")
hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")

hl.config({
    general = {
        layout = "scrolling",
        gaps_in = 5,
        gaps_out = 10,
        border_size = 2,
        col = {
            active_border = rgb(fp.colors.accent),
            inactive_border = rgb(fp.colors.ui),
        },
        -- At the strip's edge a focus bind stops, as in niri, instead of picking some other window.
        no_focus_fallback = true,
    },
    decoration = {
        rounding = 8,
        blur = { enabled = true, xray = false },
        shadow = { enabled = true, range = 30, render_power = 2, offset = { 0, 5 }, color = "rgba(" .. fp.colors.black .. "99)" },
    },
    scrolling = {
        column_width = columns.default_width,
        explicit_column_widths = "0.33333, 0.5, 0.66667, 1.0",
        -- niri keeps a lone column at its own width and stops at the strip's ends.
        fullscreen_on_one_column = false,
        wrap_focus = false,
        wrap_swapcol = false,
        -- niri's focus-follows-mouse max-scroll-amount "0%": hovering never scrolls the strip.
        follow_min_visible = 1.0,
    },
    group = {
        -- A new window opens beside a tabbed column, not as another tab in it.
        auto_group = false,
        col = { border_active = rgb(fp.colors.accent), border_inactive = rgb(fp.colors.ui) },
        -- niri's tab indicator: a bare strip, and none for a single window.
        groupbar = {
            col = { active = rgb(fp.colors.accent), inactive = rgb(fp.colors.ui) },
            render_titles = false,
            gradients = false,
            disable_when_only = true,
        },
    },
    input = {
        kb_layout = "eu",
        accel_profile = "flat",
        -- Hover focuses, but only on crossing into a window: after a focus bind, moving the
        -- pointer inside the window it rests on takes nothing back.
        follow_mouse = 1,
        mouse_refocus = false,
    },
    -- niri without warp-mouse-to-focus: a focus bind leaves the pointer where it is. Taking
    -- it along to another monitor is fp.pointer's job.
    cursor = {
        no_warps = true,
    },
    binds = {
        window_direction_monitor_fallback = true,
        -- Every wheel notch counts, as in niri; the default drops those within 300 ms.
        scroll_event_delay = 0,
    },
    misc = {
        middle_click_paste = false,
        background_color = "rgb(" .. fp.colors.bg .. ")",
        disable_hyprland_logo = true,
        force_default_wallpaper = 0,
        -- Stands in for niri's honor-xdg-activation-with-invalid-serial.
        focus_on_activate = true,
    },
    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },
})

-- niri: eased 150 ms open/close under a 0.8 slowdown, and its critically damped view spring.
hl.curve("fpOut", { type = "bezier", points = { { 0.25, 0.46 }, { 0.45, 0.94 } } })
hl.curve("fpSpring", { type = "spring", mass = 1, stiffness = 800, damping = 56.6 })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 1.2, bezier = "fpOut", style = "popin 90%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.2, bezier = "fpOut", style = "popin 90%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 4, spring = "fpSpring" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, spring = "fpSpring", style = "slidevert" })

-- DMS surfaces blur what is behind them rather than only the wallpaper.
hl.layer_rule({ match = { namespace = "^dms:" }, blur = true, xray = false, ignore_alpha = 0 })

-- agent-note-open's glow viewer floats over the session that opened it.
hl.window_rule({
    match = { class = [[^dev\.fireproof\.notes$]] },
    float = true,
    center = true,
    size = { "monitor_w*0.5", "monitor_h*0.8" },
})

-- Content types drive the per-monitor `vrr = 3` above; desktop apps stay out of VRR.
hl.window_rule({ match = { class = "^steam_app_" }, content = "game" })
hl.window_rule({ match = { class = "^gamescope$" }, content = "game" })
hl.window_rule({ match = { class = "^mpv$" }, content = "video" })

-- Shadows only on floating windows.
hl.window_rule({ match = { float = false }, no_shadow = true })
