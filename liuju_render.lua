local Renderer = {}
Renderer.__index = Renderer

local MONTHS = { "Jan.", "Feb.", "Mar.", "Apr.", "May", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec." }
local WEEKDAYS = { "日", "一", "二", "三", "四", "五", "六" }
local WEEKDAYS_EN = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
local WEEKDAY_OFFSETS = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
local BREAKS = { ["，"] = true, ["。"] = true, ["；"] = true, ["！"] = true, ["？"] = true }
local SUFFIX = { ["”"] = true, ["’"] = true, ["」"] = true, ["』"] = true,
    ["》"] = true, ["）"] = true, ["】"] = true, ["…"] = true }

local function date_parts(date)
    local y, m, d = date:match("^(%d%d%d%d)%.(%d%d)%.(%d%d)$")
    if not y then return end
    local year, month, day = tonumber(y), tonumber(m), tonumber(d)
    if not MONTHS[month] then return end
    if month < 3 then year = year - 1 end
    local weekday = (year + math.floor(year / 4) - math.floor(year / 100)
        + math.floor(year / 400) + WEEKDAY_OFFSETS[month] + day) % 7 + 1
    return MONTHS[month], d, weekday, m
end

local function phrase_lines(value)
    local parts, start, pending = {}, 1, false
    for position, char in value:gmatch("()(.[\128-\191]*)") do
        if pending and not BREAKS[char] and not SUFFIX[char] then
            if char ~= "\n" then
                parts[#parts + 1] = value:sub(start, position - 1)
                start = position
            end
            pending = false
        end
        if BREAKS[char] then pending = true end
    end
    if start == 1 then return value end
    parts[#parts + 1] = value:sub(start)
    return table.concat(parts, "\n")
end

function Renderer.new(core, layout, draw)
    return setmetatable({ core = core, layout = layout, draw = draw }, Renderer)
end

function Renderer:render(book, entry, filename, width, height)
    local style = self.layout.style(book.style)
    local l = self.layout.for_screen(width, height, style.id)
    local draw, resources, canvas = self.draw, {}
    local function text(value, box, options)
        options = options or {}
        options.gray = options.gray or l.fg
        options.bgcolor = options.bgcolor or l.bg
        options.align = box.align
        options.line_height = box.line_height
        options.max_height = box.h
        local widget = draw:text(value, box.w, box.size, options)
        resources[#resources + 1] = widget
        if widget:getAllLineCount() > widget:getVisLineCount() then return widget, math.huge end
        return widget, widget:getSize().h
    end
    local function release(widget)
        for i, resource in ipairs(resources) do
            if resource == widget then resources[i] = false; break end
        end
        widget:free()
    end
    local function caption(value, box, options, shorten, suffix)
        suffix = suffix or ""
        local widget, h = text(value .. suffix, box, options)
        while h > box.h and box.min_size and box.size > box.min_size do
            release(widget)
            box.size = math.max(box.min_size, box.size - l.p(4))
            widget, h = text(value .. suffix, box, options)
        end
        if shorten and h > box.h then
            release(widget)
            widget = nil
            local low, high = 1, #(self.core.characters(value) or {}) - 1
            while low <= high do
                local middle = math.floor((low + high) / 2)
                local candidate, height = text(self.core.shorten(value, middle) .. suffix, box, options)
                if height <= box.h then
                    if widget then release(widget) end
                    widget, h = candidate, height
                    low = middle + 1
                else
                    release(candidate)
                    high = middle - 1
                end
            end
        end
        if widget and h <= box.h then
            widget:paintTo(canvas, box.x, box.y + math.floor((box.h - h) / 2))
        end
    end
    local function disc(d)
        local radius = d.radius
        local function round(n) return math.floor(n + 0.5) end
        local function circle(r, gray) draw:circle(canvas, d.x, d.y, math.max(1, r), gray) end
        local track = round(radius * 0.72)
        circle(radius, 255)
        circle(radius - math.max(1, round(radius / 28)), 0)
        circle(track, 255)
        circle(track - math.max(1, round(radius / 56)), 0)
        circle(round(radius * 0.27), 255)
        circle(round(radius * 0.10), 0)
    end
    local ok, success, reason = pcall(function()
        local body, blocks, height_used = l.body, {}, 0
        local function block(value, size, gap, gray, split)
            local box = { w = body.w, h = body.h - height_used - gap,
                size = size, line_height = body.line_height }
            if box.h <= 0 then return false end
            local formatted = split and phrase_lines(value) or value
            local widget, h = text(formatted, box, { gray = gray })
            if h > box.h and formatted ~= value then
                release(widget)
                widget, h = text(value, box, { gray = gray })
            end
            if h > box.h then return false end
            blocks[#blocks + 1] = { widget = widget, height = h, gap = gap }
            height_used = height_used + gap + h
            return true
        end
        if entry.text ~= "" and not block(entry.text, body.size, 0, l.fg, style.id ~= "calendar") then
            return false, "layout"
        end
        if entry.note ~= "" then
            if not block("笔记", l.p(22), height_used > 0 and l.p(31) or 0, l.muted)
                    or not block(entry.note, l.p(42), l.p(10), l.fg) then
                return false, "layout"
            end
        end

        canvas = draw:canvas(width, height)
        draw:background(canvas, style.asset, width, height)
        local y = body.bottom and math.min(body.y, body.bottom - height_used) or body.y
        for _, item in ipairs(blocks) do
            y = y + item.gap
            item.widget:paintTo(canvas, body.x, y)
            y = y + item.height
        end
        local date = entry.date
        if l.footer then
            draw:rect(canvas, 0, l.footer.y, width, l.footer.h, 0)
            disc(l.disc)
            local suffix = date ~= "" and "  ·  " .. date or ""
            caption(book.title, l.title, { bold = true, gray = 255, bgcolor = 0 }, true, suffix)
        else
            local month, day, weekday, number = date_parts(date)
            if month and l.month then
                caption(month, l.month, { bold = true })
                caption(day, l.day, { bold = true })
                caption("星期" .. WEEKDAYS[weekday], l.weekday, { bold = true })
            elseif month then
                caption(number .. "." .. day .. "  /  " .. WEEKDAYS_EN[weekday], l.date, { bold = true })
            end
            caption(book.title, l.title, { bold = true }, true)
            caption("留句 · 阅读摘录", l.subtitle, { gray = l.muted })
        end
        local written, err = canvas:writePNG(filename)
        -- Older KOReader versions return nothing here. The store validates the PNG.
        if written == false or (written == nil and err ~= nil) then
            return nil, "write: " .. tostring(err)
        end
        return true
    end)
    for _, widget in ipairs(resources) do if widget then pcall(widget.free, widget) end end
    if canvas then pcall(canvas.free, canvas) end
    if not ok then return nil, tostring(success) end
    return success, reason
end

return Renderer
