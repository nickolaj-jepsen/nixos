-- niri's column actions that Hyprland lacks, written against the Lua layout data.

local M = {}

M.default_width = 0.4

-- A tiled window's scrolling column ({ index, width, windows }); nil when floating.
local function column(w)
    local l = w and w.layout
    return l and l.column or nil
end

-- Lowest and highest column index on `w`'s workspace.
local function column_range(w)
    local lo, hi
    for _, o in ipairs(hl.get_workspace_windows(w.workspace --[[@as HL.Workspace]])) do
        local c = column(o)
        if c then
            lo = math.min(lo or c.index, c.index)
            hi = math.max(hi or c.index, c.index)
        end
    end
    return lo, hi
end

-- The enabled monitor nearest to `m` on the left ("l") or right ("r"), by layout position.
local function neighbour_monitor(m, dir)
    local best
    for _, o in ipairs(hl.get_monitors()) do
        if o.id ~= m.id and o.enabled and not o.is_mirror then
            local ok = (dir == "l" and o.x < m.x) or (dir == "r" and o.x > m.x)
            if ok and (not best or (dir == "l" and o.x > best.x) or (dir == "r" and o.x < best.x)) then
                best = o
            end
        end
    end
    return best
end

-- Carries `w`'s whole column (every window in it, in order) to a monitor or a workspace; `where`
-- is that field of hl.dsp.window.move's argument.
local function carry_column(w, where)
    local c = column(w)
    local windows = c and { table.unpack(c.windows) } or { w }
    for i, cw in ipairs(windows) do
        local move = { window = cw, follow = true }
        for field, target in pairs(where) do
            move[field] = target
        end
        hl.dispatch(hl.dsp.window.move(move))
        if i > 1 then
            -- Each window lands as a new column right of the previous one; fold it back in.
            hl.dispatch(hl.dsp.focus({ window = cw }))
            hl.dispatch(hl.dsp.layout("consume_or_expel prev"))
        end
    end
    hl.dispatch(hl.dsp.focus({ window = w }))
end

-- niri's move-column-to-workspace.
function M.move_column_to_workspace(workspace)
    local w = hl.get_active_window()
    if w then
        carry_column(w, { workspace = workspace })
    end
end

-- Workspace ids: 1-5 static, a monitor's first one right after, then the projects, then the
-- ones made by walking past the end. Sorting by id gives niri's top-to-bottom order.
M.first_project_id = 11
local first_dynamic_id = 51

-- niri's focus-workspace-down/up: along the monitor's own workspaces without wrapping, with an
-- empty one always waiting below the last.
function M.focus_workspace(delta)
    local current = hl.get_active_workspace()
    if not (current and current.monitor) then
        return
    end
    local strip, highest = {}, first_dynamic_id - 1
    for _, ws in ipairs(hl.get_workspaces()) do
        if not ws.special and ws.id then
            highest = math.max(highest, ws.id)
            if ws.monitor and ws.monitor.id == current.monitor.id then
                strip[#strip + 1] = ws
            end
        end
    end
    table.sort(strip, function(a, b)
        return a.id < b.id
    end)
    for i, ws in ipairs(strip) do
        if ws.id == current.id then
            local target = strip[i + delta]
            if target then
                hl.dispatch(hl.dsp.focus({ workspace = target.id }))
            elseif delta > 0 and ws.windows > 0 then
                hl.dispatch(hl.dsp.focus({ workspace = highest + 1 }))
            end
            return
        end
    end
end

-- niri's move-column-{left,right}-or-to-monitor-*: swap within the strip, and at its edge carry the
-- whole column to the neighbouring monitor.
function M.move_column(dir)
    local w = hl.get_active_window()
    local c = column(w)
    if not (w and c) then
        hl.dispatch(hl.dsp.window.move({ direction = dir }))
        return
    end
    local lo, hi = column_range(w)
    if (dir == "l" and c.index > lo) or (dir == "r" and c.index < hi) then
        hl.dispatch(hl.dsp.layout("swapcol " .. dir))
        return
    end
    local target = w.monitor and neighbour_monitor(w.monitor, dir)
    if not target then
        return
    end
    carry_column(w, { monitor = target })
end

-- niri's focus-column-first/last.
function M.focus_column(which)
    local w = hl.get_active_window()
    if not (w and column(w)) then
        return
    end
    local lo, hi = column_range(w)
    local steps = which == "first" and column(w).index - lo or hi - column(w).index
    -- Column by column, so it lands on the window that column last had focused.
    for _ = 1, steps do
        hl.dispatch(hl.dsp.layout("focus " .. (which == "first" and "l" or "r")))
    end
end

-- niri's maximize-column: the whole column, stack included, to full width and back.
local unmaximized = {}
function M.maximize_column()
    local w = hl.get_active_window()
    local c = column(w)
    if not c then
        return
    end
    local key = c.windows[1].address
    if c.width >= 0.99 then
        hl.dispatch(hl.dsp.layout("colresize " .. (unmaximized[key] or M.default_width)))
        unmaximized[key] = nil
    else
        unmaximized[key] = c.width
        hl.dispatch(hl.dsp.layout("colresize 1.0"))
    end
end

-- niri's toggle-column-tabbed-display: every window of the column into one group, and back
-- into one column.
function M.toggle_tabbed()
    local w = hl.get_active_window()
    if not w then
        return
    end
    local members = {}
    if w.group then
        local tabs = {}
        for i, m in ipairs(w.group.members) do
            members[i], tabs[i] = m, m
        end
        hl.dispatch(hl.dsp.group.toggle())
        -- Dissolved, each member is a column of its own; fold them into the leftmost.
        table.sort(members, function(a, b)
            return column(a).index < column(b).index
        end)
        for i = 2, #members do
            hl.dispatch(hl.dsp.focus({ window = members[i] }))
            hl.dispatch(hl.dsp.layout("consume_or_expel prev"))
        end
        -- The columns came out in no promised order; put the stack back in tab order.
        for i, m in ipairs(tabs) do
            for _ = 1, #tabs do
                if m.layout.index_in_column < i then
                    break
                end
                hl.dispatch(hl.dsp.window.move({ window = m, direction = "u" }))
            end
        end
    else
        local c = column(w)
        for i, m in ipairs(c and c.windows or { w }) do
            members[i] = m
        end
        -- From the top window down, so the tabs keep the column's order.
        hl.dispatch(hl.dsp.focus({ window = members[1] }))
        hl.dispatch(hl.dsp.group.toggle())
        for i = 2, #members do
            if members[1].group then
                members[1].group:add(members[i])
            end
        end
    end
    hl.dispatch(hl.dsp.focus({ window = w }))
end

-- Up and down walk a tabbed column's tabs before leaving it, as niri's do.
function M.focus_vertical(dir)
    local w = hl.get_active_window()
    local g = w and w.group
    if g and dir == "d" and g.current_index < g.size then
        hl.dispatch(hl.dsp.group.next())
    elseif g and dir == "u" and g.current_index > 1 then
        hl.dispatch(hl.dsp.group.prev())
    else
        hl.dispatch(hl.dsp.focus({ direction = dir }))
    end
end

-- niri's move-column-to-first/last.
function M.move_column_to(which)
    local w = hl.get_active_window()
    local c = column(w)
    if not c then
        return
    end
    local lo, hi = column_range(w)
    local steps = which == "first" and c.index - lo or hi - c.index
    for _ = 1, steps do
        hl.dispatch(hl.dsp.layout("swapcol " .. (which == "first" and "l" or "r")))
    end
end

-- niri's set-window-height ±N%: Hyprland resizes in pixels, so scale by the monitor.
function M.grow_height(frac)
    local m = hl.get_active_monitor()
    if m then
        hl.dispatch(hl.dsp.window.resize({ x = 0, y = math.floor(m.height / m.scale * frac), relative = true }))
    end
end

return M
