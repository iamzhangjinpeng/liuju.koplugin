-- This entry point stays in place while an online update is staged or tested.
local base = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
return dofile(base .. "liuju_boot.lua").new(base):load()
