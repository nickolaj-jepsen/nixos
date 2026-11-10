-- Project workspaces (niri-dynamic-workspaces) and terminals (ghostty-here).

local fp = require("fp.data")
local columns = require("fp.columns")
local util = require("fp.util")
local mod, ghostty, sh_quote = util.mod, util.ghostty, util.sh_quote

local M = {}

-- Static workspaces Mod+q..t, kept alive on the primary output like niri's "01".."05".
local static = { "q", "w", "e", "r", "t" }
local static_names = { q = "browser", r = "music", t = "diff" }
for i, key in ipairs(static) do
    if fp.primary ~= "" then
        hl.workspace_rule({
            workspace = tostring(i),
            monitor = fp.primary,
            persistent = true,
            default = i == 1,
            default_name = static_names[key],
        })
    end
    hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, function()
        columns.move_column_to_workspace(i)
    end)
end

-- Workspace name -> project. Metadata comes from config, so nothing is encoded in the name and
-- nothing is lost when a reload resets Lua state.
local function project_of(ws)
    if not ws then
        return nil
    end
    for _, p in pairs(fp.workspaces) do
        if p.name == ws.name then
            return p
        end
    end
end

-- Spawn tag -> continuation; window.open below advances the chain.
local waiting = {}
local spawn_seq = 0

-- Spawns `cmds` one at a time onto workspace `sel`, each after the previous window opened (or 5 s
-- passed, e.g. `code` handing off to a running instance), so columns follow command order. The
-- exec rule ties each window to its own process, so a workspace switch meanwhile changes nothing.
local function spawn_in_order(cmds, sel, i)
    i = i or 1
    local cmd = cmds[i]
    if not cmd then
        return
    end
    spawn_seq = spawn_seq + 1
    local tag = "fpspawn" .. spawn_seq
    local done = false
    local function advance()
        if done then
            return
        end
        done = true
        waiting[tag] = nil
        spawn_in_order(cmds, sel, i + 1)
    end
    waiting[tag] = advance
    hl.exec_cmd(cmd, { workspace = sel .. " silent", tag = "+" .. tag })
    hl.timer(advance, { timeout = 5000, type = "oneshot" })
end

-- Focus a project's workspace, creating it and starting its programs the first time. Hyprland
-- destroys it again once it is empty and unfocused, so no cleanup daemon is needed.
function M.project(key)
    local p = fp.workspaces[key]
    if not p then
        return
    end
    local sel = "name:" .. p.name
    local fresh = hl.get_workspace(sel) == nil
    hl.dispatch(hl.dsp.focus({ workspace = sel }))
    if fresh then
        spawn_in_order(p.programs, sel)
    end
end

function M.move_to_project(key)
    local p = fp.workspaces[key]
    if p then
        hl.dispatch(hl.dsp.window.move({ workspace = "name:" .. p.name, follow = false }))
    end
end

function M.close_project(key)
    local p = fp.workspaces[key]
    if not p or not hl.get_workspace("name:" .. p.name) then
        return
    end
    for _, w in ipairs(hl.get_workspace_windows("name:" .. p.name)) do
        hl.dispatch(hl.dsp.window.close({ window = w }))
    end
end

-- A key-per-project submap stands in for the overlay; a notification lists the keys meanwhile.
local hints = {}
local keys = {}
for key in pairs(fp.workspaces) do
    keys[#keys + 1] = key
end
table.sort(keys)

local function project_submap(name, title, action)
    local lines = { title }
    for _, key in ipairs(keys) do
        lines[#lines + 1] = key .. "  " .. fp.workspaces[key].name
    end
    hints[name] = table.concat(lines, "\n")
    hl.define_submap(name, function()
        for _, key in ipairs(keys) do
            local function pick()
                hl.dispatch(hl.dsp.submap("reset"))
                action(key)
            end
            -- Mod may still be held from the bind that opened the submap.
            hl.bind(key, pick)
            hl.bind(mod .. " + " .. key, pick)
        end
        hl.bind("escape", hl.dsp.submap("reset"))
    end)
end

project_submap("fp-switch", "Switch to project", M.project)
project_submap("fp-move", "Move window to project", M.move_to_project)
project_submap("fp-close", "Close project's windows", M.close_project)

local hint
hl.on("keybinds.submap", function(name)
    if hint then
        hint:dismiss()
        hint = nil
    end
    if hints[name] then
        hint = hl.notification.create({ text = hints[name], timeout = 10000 })
    end
end)

-- ghostty-here: start where you are working. Directory order: the focused terminal's shell, the
-- project's directory, another terminal's shell on this workspace, then $HOME. With `stack`, the
-- new window joins the focused column instead of opening one beside it.
function M.terminal(stack)
    local w = hl.get_active_window()
    local ws = hl.get_active_workspace()
    local p = project_of(ws)
    local pids = {}
    if w and w.class == ghostty then
        pids[#pids + 1] = tostring(w.pid)
    end
    if not (p and p.path) and ws then
        for _, o in ipairs(hl.get_workspace_windows(ws)) do
            if o.class == ghostty and o ~= w then
                pids[#pids + 1] = tostring(o.pid)
            end
        end
    end
    -- The /proc walk runs in the spawned shell, not on the compositor thread.
    local cmd = string.format(
        'exec ghostty --working-directory="$(%s %s %s)"',
        fp.bin.shell_cwd,
        sh_quote((p and p.path) or fp.home),
        table.concat(pids, " ")
    )
    if stack and w and not w.floating then
        hl.exec_cmd(cmd, { tag = "+fpstack" })
    else
        hl.exec_cmd(cmd)
    end
end

hl.on("window.open", function(w)
    for _, t in ipairs(w.tags) do
        local tag = t:gsub("%*$", "")
        if tag == "fpstack" then
            -- It opened as the column right of the one it was launched from; fold it in at the
            -- bottom. Plain `consume` would merge it into the next column instead (0.57, tested).
            hl.dispatch(hl.dsp.focus({ window = w }))
            hl.dispatch(hl.dsp.layout("consume_or_expel prev"))
        elseif waiting[tag] then
            waiting[tag]()
        end
    end
end)

return M
