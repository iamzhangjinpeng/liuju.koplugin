local _ = require("gettext")
if not ... then
    local base = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.symlinkattributes(base .. ".liuju-versions", "mode") == "directory" then
        local boot = dofile(base .. "liuju_boot.lua").new(base)
        local active = boot:active_metadata()
        if active then return active end
    end
end
return {
    fullname = _("留句"),
    description = _("将当前书的简短高亮和批注生成为锁屏小票，换书时自动切换。"),
    author = "iamzhangjinpeng",
    version = "1.2.1",
    device_support = { "Kindle" },
}
