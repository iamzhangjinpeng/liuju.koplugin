local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local LuaSettings = require("luasettings")
local RenderImage = require("ui/renderimage")
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

local function list(dir)
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    return names
end

local function remove(path)
    local ok, err = os.remove(path)
    assert(ok, "Cannot remove stale wallpaper: " .. tostring(err))
end
local function uint32(s)
    if not s or #s ~= 4 then return end
    local a,b,c,d = s:byte(1,4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
local function valid_png_header(path, w, h)
    local f = io.open(path, "rb")
    if not f then return end
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

function Store.decode_png(path, w, h)
    if not valid_png_header(path, w, h) then return end
    local ok, image = pcall(RenderImage.renderImageFile, RenderImage, path)
    if not ok then return end
    if image and image:getWidth() == w and image:getHeight() == h then return image end
    if image then image:free() end
end

function Store.valid_png(path, w, h)
    local image = Store.decode_png(path, w, h)
    if not image then return false end
    image:free()
    return true
end

function Store.open_index(state_root, book_id)
    assert(book_id:match("^%x+$") and #book_id == 64, "Invalid book ID")
    local index = LuaSettings:open(state_root .. "/" .. book_id .. ".lua")
    if type(index.data) ~= "table" then index.data = {} end
    return index
end

function Store.new(root, state_root, book_id, width, height)
    local index = Store.open_index(state_root, book_id)
    directory(root)
    directory(state_root)
    local book_dir = root .. "/" .. book_id
    local dir = book_dir .. "/pool"
    directory(book_dir)
    directory(dir)
    local skipped = index:readSetting("skipped")
    return setmetatable({
        dir = dir, book_dir = book_dir, state_root = state_root, book_id = book_id, width = width, height = height,
        index = index, skipped = type(skipped) == "table" and skipped or {},
        counts = index:readSetting("counts"),
        fallback = state_root .. "/" .. book_id .. "-cover.png",
    }, Store)
end

local function is_candidate(dir, path)
    return type(path) == "string" and path:sub(1, #dir + 1) == dir .. "/" and managed(path:sub(#dir + 2))
        and mode(path) == "file"
end

local function indexed_count(counts, name)
    local count = type(counts) == "table" and counts[name]
    if type(count) == "number" and count > 0 and count <= 200 and count % 1 == 0 then return count end
end

function Store.indexed_candidate(index, dir, path, limit)
    if not is_candidate(dir, path) then return false end
    local count = indexed_count(index:readSetting("counts"), path:sub(#dir + 2))
    return count ~= nil and count <= limit
end

function Store.decode_candidate(dir, path, width, height)
    if is_candidate(dir, path) then return Store.decode_png(path, width, height) end
end

function Store.discard_candidate(dir, path)
    if is_candidate(dir, path) then remove(path) end
end

function Store:verify_cached(name)
    local path = self.dir .. "/" .. name
    local image = Store.decode_candidate(self.dir, path, self.width, self.height)
    if image then image:free(); return true end
    Store.discard_candidate(self.dir, path)
    return false
end

local function same_counts(old, new)
    if type(old) ~= "table" then return false end
    for name, count in pairs(old) do if new[name] ~= count then return false end end
    for name, count in pairs(new) do if old[name] ~= count then return false end end
    return true
end

function Store:_exclude(path, name)
    local dir = self.book_dir .. "/excluded"
    directory(dir)
    local target, i = dir .. "/" .. name, 0
    while mode(target) do
        i = i + 1
        target = dir .. "/" .. i .. "-" .. name
    end
    local ok, err = os.rename(path, target)
    assert(ok, "Cannot move foreign wallpaper: " .. tostring(err))
end

function Store:reconcile(entries, force)
    local counts, skipped, available = {}, {}, {}
    for _, item in ipairs(entries) do
        counts[item.filename] = item.count
        if not force then skipped[item.filename] = self.skipped[item.filename] end
    end
    for _, name in ipairs(list(self.dir)) do
        local path = self.dir .. "/" .. name
        local kind = mode(path)
        if kind == "file" and managed(name) then
            if counts[name] and valid_png_header(path, self.width, self.height) then
                available[name] = true
            elseif not counts[name] and not indexed_count(self.counts, name) then
                self:_exclude(path, name)
            else
                remove(path)
            end
        elseif kind and kind ~= "directory" then
            self:_exclude(path, name)
        end
    end
    -- Reuse images generated by rc.2 in the old flat book directory.
    for _, name in ipairs(list(self.book_dir)) do
        local path = self.book_dir .. "/" .. name
        if managed(name) and mode(path) == "file" then
            if counts[name] and not available[name] and valid_png_header(path, self.width, self.height) then
                local ok, err = os.rename(path, self.dir .. "/" .. name)
                assert(ok, "Cannot migrate cached wallpaper: " .. tostring(err))
                available[name] = true
            elseif counts[name] or indexed_count(self.counts, name) then
                remove(path)
            else
                self:_exclude(path, name)
            end
        end
    end
    self.skipped = skipped
    if not same_counts(self.counts, counts) then
        self.counts = counts
        self.index:saveSetting("counts", counts)
        self:save_index()
    end
    return available
end

function Store:filter_limit(limit)
    if type(self.counts) ~= "table" then
        -- Older caches lack counts. Keep their files for the next verified open.
        if self.counts ~= false then
            self.counts = false
            self.index:saveSetting("counts", false)
            self.index:flush()
        end
        return {}, 0
    end
    local entries = {}
    for name in pairs(self.counts) do
        local count = indexed_count(self.counts, name)
        if count and count <= limit then
            entries[#entries + 1] = { filename = name, count = count }
        end
    end
    return self:reconcile(entries, false), #entries
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

function Store:images(limit, allowed)
    local files = {}
    if not allowed and type(self.counts) ~= "table" then return files end
    for _, dir in ipairs({ self.dir, self.book_dir }) do
        for _, name in ipairs(list(dir)) do
            local path = dir .. "/" .. name
            local count = indexed_count(self.counts, name)
            local matches = allowed and allowed[name] or (not allowed and count and count <= (limit or math.huge))
            if matches and is_candidate(dir, path) then
                files[#files + 1] = path
            end
        end
        if #files > 0 then break end
    end
    table.sort(files)
    return files
end

Store.managed = managed
return Store
