-- niri moves the pointer to the centre of a monitor that gets focus while the pointer is elsewhere;
-- without that, the next nudge of the mouse would hand focus back to the monitor it was left on.

hl.on("monitor.focused", function(m)
    local p = hl.get_cursor_pos()
    if not (m and p) then
        return
    end
    local w, h = m.width / m.scale, m.height / m.scale
    if p.x < m.x or p.x >= m.x + w or p.y < m.y or p.y >= m.y + h then
        hl.dispatch(hl.dsp.cursor.move({ x = math.floor(m.x + w / 2), y = math.floor(m.y + h / 2) }))
    end
end)
