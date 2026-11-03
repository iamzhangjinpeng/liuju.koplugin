local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local LuaSettings = require("luasettings")
local Store = {}
Store.__index = Store

local function mode(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path, "mode") end
    return lfs.attributes(path, "mode")
end
local function directory(path)
    if mode(path) == "link" then error("Refusing symlink directory: " .. path) end
    util.makePath(path)
    assert(mode(path) == "directory", "Cannot create directory: " .. path)
end
local function managed(name)
    return type(name) == "string" and name:match("^liuju%-%x+%.png$") and #name == 74
end
local function uint32(s)
    if not s or #s ~= 4 then return end
    local a,b,c,d = s:byte(1,4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
function Store.valid_png(path, w, h)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(24)
    local size = f:seek("end")
    local tail
    if size and size >= 45 then f:seek("end", -12); tail = f:read(12) end
    f:close()
    return head and head:sub(1,8) == "\137PNG\r\n\26\n"
        and head:sub(13,16) == "IHDR"
        and uint32(head:sub(17,20)) == w and uint32(head:sub(21,24)) == h
        and tail == "\0\0\0\0IEND\174\66\96\130"
end

function Store.new(root, state_root, book_id, width, height)
    assert(book_id:match("^%x+$") and #book_id == 64, "Invalid book ID")
    directory(root)
    directory(state_root)
    local dir = root .. "/" .. book_id
    directory(dir)
    local index = LuaSettings:open(state_root .. "/" .. book_id .. ".lua")
    return setmetatable({
        dir = dir, state_root = state_root, book_id = book_id, width = width, height = height,
        index = index, skipped = index:readSetting("skipped") or {},
        fallback = state_root .. "/" .. book_id .. "-cover.png",
    }, Store)
end

function Store:has(name)
    return managed(name) and mode(self.dir .. "/" .. name) == "file"
        and Store.valid_png(self.dir .. "/" .. name, self.width, self.height)
end

function Store:reconcile(entries, force)
    local wanted, skipped = {}, {}
    for _, item in ipairs(entries) do
        wanted[item.filename] = true
        if not force then skipped[item.filename] = self.skipped[item.filename] end
    end
    for name in lfs.dir(self.dir) do
        if managed(name) and not wanted[name] and mode(self.dir .. "/" .. name) == "file" then
            local ok, err = os.remove(self.dir .. "/" .. name)
            if not ok then error("Cannot remove stale wallpaper: " .. tostring(err)) end
        end
    end
    self.skipped = skipped
end

function Store:save_index()
    self.index:saveSetting("skipped", self.skipped)
    self.index:saveSetting("width", self.width)
    self.index:saveSetting("height", self.height)
    local result = self.index:flush()
    if result == false then error("Cannot save image index") end
end

function Store:temp_path()
    return self.state_root .. "/" .. self.book_id .. ".png.tmp"
end

function Store:write(renderer, book, entry)
    local tmp = self:temp_path()
    os.remove(tmp)
    local ok, reason = renderer:render(book, entry, tmp, self.width, self.height)
    if not ok then os.remove(tmp); return ok, reason end
    if not Store.valid_png(tmp, self.width, self.height) then
        os.remove(tmp)
        return nil, "invalid PNG"
    end
    local target = entry and (self.dir .. "/" .. entry.filename) or self.fallback
    local renamed, err = os.rename(tmp, target)
    if not renamed then os.remove(tmp); return nil, "rename: " .. tostring(err) end
    return true
end

function Store:images()
    local files = {}
    for name in lfs.dir(self.dir) do
        if managed(name) and self:has(name) then files[#files + 1] = self.dir .. "/" .. name end
    end
    table.sort(files)
    return files
end

Store.managed = managed
return Store
