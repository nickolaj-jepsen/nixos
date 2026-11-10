local M = {}

M.mod = "SUPER"
M.ghostty = "com.mitchellh.ghostty"

function M.rgb(hex)
    return "rgb(" .. hex .. ")"
end

function M.sh_quote(s)
    return "'" .. (tostring(s):gsub("'", [['\'']])) .. "'"
end

function M.run(cmd)
    hl.dispatch(hl.dsp.exec_cmd(cmd))
end

return M
