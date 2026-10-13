-- Find Files hotkey. dofile() this from ~/.config/hypr/hyprland.lua or
-- ~/.config/hypr/bindings.lua, or bind the command to a key of your own.

local KEY = "SUPER + CTRL + SHIFT + F"

local bind = (o and o.bind) or function(key, description, command)
  hl.bind(key, hl.dsp.exec_cmd(command), { description = description })
end

-- Pop like the launcher: no compositor fade on the layer.
hl.layer_rule({ match = { namespace = "tqdesign-find-files" }, no_anim = true, animation = "none" })

bind(KEY, "Find files", "omarchy-shell shell toggle tqdesign.find-files")
