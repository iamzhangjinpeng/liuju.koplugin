local Core = {}
local sha256 = require("ffi/sha2").sha256

Core.VERSION = "0.1.0-rc.2"
Core.LAYOUT_VERSION = "album-poster-2"
Core.DEFAULT_LIMIT = 80

local function whitespace(cp)
    return cp == 32 or (cp >= 9 and cp <= 13) or cp == 0x85 or cp == 0xA0
        or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200B)
        or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F
        or cp == 0x3000 or cp == 0xFEFF
end

-- LuaJIT strings contain bytes. Decode strictly so invalid UTF-8 never reaches
-- the native text shaper, and whitespace is counted consistently.
function Core.characters(text)
    if type(text) ~= "string" then return nil end
    local result, i = {}, 1
    while i <= #text do
        local first = text:byte(i)
        local n, cp, minimum
        if first < 0x80 then n, cp, minimum = 1, first, 0
        elseif first >= 0xC2 and first <= 0xDF then n, cp, minimum = 2, first - 0xC0, 0x80
        elseif first >= 0xE0 and first <= 0xEF then n, cp, minimum = 3, first - 0xE0, 0x800
        elseif first >= 0xF0 and first <= 0xF4 then n, cp, minimum = 4, first - 0xF0, 0x10000
        else return nil end
        for j = 1, n - 1 do
            local b = text:byte(i + j)
            if not b or b < 0x80 or b > 0xBF then return nil end
            cp = cp * 64 + b - 0x80
        end
        if cp < minimum or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return nil end
        if (cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13) or cp == 127 then return nil end
        result[#result + 1] = { text = text:sub(i, i + n - 1), cp = cp, space = whitespace(cp) }
        i = i + n
    end
    return result
end

function Core.count(text)
    local chars = Core.characters(text)
    if not chars then return nil end
    local count = 0
    for _, ch in ipairs(chars) do if not ch.space then count = count + 1 end end
    return count
end

function Core.clean(text)
    text = type(text) == "string" and text:gsub("\r\n", "\n"):gsub("\r", "\n") or ""
    local chars = Core.characters(text)
    if not chars then return nil end
    local first, last = 1, #chars
    while first <= last and chars[first].space do first = first + 1 end
    while last >= first and chars[last].space do last = last - 1 end
    local result = {}
    for i = first, last do result[#result + 1] = chars[i].text end
    return table.concat(result)
end

function Core.shorten(text, length)
    local chars = Core.characters(text) or {}
    if #chars <= length then return text end
    local result = {}
    for i = 1, math.max(0, length - 1) do result[#result + 1] = chars[i].text end
    return table.concat(result) .. "…"
end

function Core.pack(values)
    local result = {}
    for i = 1, #values do
        local value = values[i]
        value = value == nil and "" or tostring(value)
        result[#result + 1] = #value .. ":" .. value
    end
    return table.concat(result)
end

local function position(value, depth)
    if type(value) ~= "table" then return tostring(value or "") end
    if (depth or 0) > 5 then return "" end
    local keys, values = {}, {}
    for key in pairs(value) do
        if type(key) == "string" or type(key) == "number" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        values[#values + 1] = Core.pack({ key, position(value[key], (depth or 0) + 1) })
    end
    return Core.pack(values)
end

function Core.hash(value) return sha256(value) end
function Core.book_id(path) return sha256(path) end

function Core.date(value)
    if type(value) ~= "string" then return "" end
    local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y or tonumber(m) < 1 or tonumber(m) > 12 then return "" end
    local year, month, day = tonumber(y), tonumber(m), tonumber(d)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then days[2] = 29 end
    if day < 1 or day > days[month] then return "" end
    return y .. "." .. m .. "." .. d
end

function Core.limit(value)
    value = tonumber(value)
    if not value or value ~= value then return Core.DEFAULT_LIMIT end
    return math.max(1, math.min(200, math.floor(value)))
end

function Core.collect(annotations, limit, render_key)
    local entries, reasons, seen = {}, {}, {}
    local function skip(reason) reasons[reason] = (reasons[reason] or 0) + 1 end
    for _, item in ipairs(type(annotations) == "table" and annotations or {}) do
        if type(item) == "table" then
            local text, note = Core.clean(item.text), Core.clean(item.note)
            local highlighted = item.drawer ~= nil or (item.pos0 ~= nil and item.pos1 ~= nil)
            if not highlighted then text = "" end -- page bookmark auto-text is not an excerpt
            local count = text and note and Core.count(text .. note)
            if not count then skip("invalid_text")
            elseif note ~= "" and item.note_format and item.note_format ~= ""
                    and item.note_format ~= "plain" and item.note_format ~= "text" then skip("formatted_note")
            elseif count == 0 then skip("empty")
            elseif count > Core.limit(limit) then skip("too_long")
            else
                local id = sha256(Core.pack({ item.datetime, position(item.page), position(item.pos0), position(item.pos1) }))
                local date = Core.date(item.datetime)
                local digest = sha256(Core.pack({ render_key, id, text, note, date }))
                if not seen[digest] then
                    seen[digest] = true
                    entries[#entries + 1] = {
                        id = id, text = text, note = note, date = date, count = count,
                        filename = "liuju-" .. digest .. ".png",
                    }
                end
            end
        else skip("invalid_text") end
    end
    return entries, reasons
end

return Core
