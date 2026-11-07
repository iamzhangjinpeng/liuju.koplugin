local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local Metadata = {}

-- Follow KOReader's sidecar locations and newest-file precedence. Its full
-- DocSettings:open also removes unreadable files, which a wallpaper read must
-- never do. An unreadable newest record is unknown, even if an older copy exists.
function Metadata.read(book)
    local name = DocSettings.getSidecarFilename(book)
    local doc = DocSettings:getSidecarDir(book, "doc") .. "/"
    local dir = DocSettings:getSidecarDir(book, "dir") .. "/"
    local candidates, newest, seen = {}, nil, {}
    local function add(path)
        if seen[path] then return end
        seen[path] = true
        local attrs, err, code = lfs.attributes(path)
        if not attrs then
            if code and code ~= 2 and code ~= 20 then error(err, 0) end
            return
        end
        if attrs.mode ~= "file" or not attrs.modification then error("invalid sidecar path: " .. path, 0) end
        local entry = { path = path, modified = attrs.modification }
        candidates[#candidates + 1] = entry
        return entry
    end
    local function add_pair(path)
        if not path or path == "" then return end
        local primary = add(path)
        local backup = add(path .. ".old")
        if primary and backup then primary.modified = math.max(primary.modified, backup.modified) end
    end
    add_pair(doc .. name)
    add(doc .. book:match("[^/]+$") .. ".lua")
    add_pair(dir .. name)
    if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
        add_pair(DocSettings:getSidecarDir(book, "hash") .. "/" .. name)
    end
    if DocSettings.getHistoryPath then add_pair(DocSettings:getHistoryPath(book)) end
    add(book .. ".kpdfview.lua")
    for _, entry in ipairs(candidates) do
        if not newest or entry.modified > newest.modified then newest = entry end
    end
    if not newest then return nil, "metadata missing" end
    local chunk, err = loadfile(newest.path, "t")
    if not chunk then return nil, err end
    setfenv(chunk, {})
    local ok, data = pcall(chunk)
    if not ok then return nil, data end
    if type(data) ~= "table" or not next(data) or (data.annotations ~= nil and type(data.annotations) ~= "table") then
        return nil, "invalid book metadata"
    end
    return data
end

return Metadata
