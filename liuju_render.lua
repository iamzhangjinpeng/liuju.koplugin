local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(core, layout, draw)
    return setmetatable({ core = core, layout = layout, draw = draw }, Renderer)
end

function Renderer:render(book, entry, filename, width, height)
    local l = self.layout.for_screen(width, height)
    local draw, resources, canvas = self.draw, {}
    local function text(value, w, size, options)
        local widget = draw:text(value, w, size, options)
        resources[#resources + 1] = widget
        return widget, widget:getSize().h
    end
    local function release(widget)
        for i, resource in ipairs(resources) do
            if resource == widget then resources[i] = false; break end
        end
        widget:free()
    end
    local function rect(x, y, w, h, gray) draw:rect(canvas, x, y, w, h, gray) end
    local function border(b, gray)
        rect(b.x, b.y, b.w, l.rule, gray)
        rect(b.x, b.y + b.h - l.rule, b.w, l.rule, gray)
        rect(b.x, b.y, l.rule, b.h, gray)
        rect(b.x + b.w - l.rule, b.y, l.rule, b.h, gray)
    end
    local function title(value, box, size, align)
        local value_now = self.core.shorten(value, 48)
        local widget, h = text(value_now, box.w, size, { bold = true, align = align })
        while h > box.h do
            local chars = self.core.characters(value_now)
            if not chars or #chars <= 2 then return end
            release(widget)
            value_now = self.core.shorten(value_now, #chars - 1)
            widget, h = text(value_now, box.w, size, { bold = true, align = align })
        end
        widget:paintTo(canvas, box.x, box.y + math.floor((box.h - h) / 2))
    end
    local function cover(box)
        if draw:cover(canvas, book.cover, box) then return end
        rect(box.x, box.y, box.w, box.h, 249)
        border(box, 168)
        local inset = l.p(16)
        title(book.title, { x = box.x + inset, y = box.y + inset,
            w = box.w - inset * 2, h = box.h - inset * 2 }, l.p(25), "center")
    end
    local ok, success, reason = pcall(function()
        local blocks, content_height = {}, 0
        if entry then
            if entry.text ~= "" then
                local widget, h = text(entry.text, l.body.w, l.quote_size)
                local width = l.body.w
                -- Balance short, plain quotes by narrowing their text block,
                -- never their font. Native shaping decides the line count;
                -- source text is passed through unchanged.
                if entry.note == "" and not entry.text:find("\n", 1, true) and widget.getAllLineCount then
                    local lines = widget:getAllLineCount()
                    if lines >= 2 and lines <= 3 then
                        local low, high = math.floor(width * 0.35), width
                        while high - low > l.p(4) do
                            local middle = math.floor((low + high) / 2)
                            local candidate, ch = text(entry.text, middle, l.quote_size)
                            if candidate:getAllLineCount() <= lines and ch <= h then
                                release(widget)
                                widget, width, high = candidate, middle, middle
                            else
                                release(candidate)
                                low = middle + 1
                            end
                        end
                    end
                end
                blocks[#blocks + 1] = { widget = widget, height = h, gap = 0,
                    x = math.floor((l.body.w - width) / 2) }
                content_height = h
            end
            if entry.note ~= "" then
                local gap = content_height > 0 and l.note_gap or 0
                local label, lh = text("笔记", l.body.w, l.label_size, { gray = 110 })
                local note, nh = text(entry.note, l.body.w, l.note_size)
                blocks[#blocks + 1] = { widget = label, height = lh, gap = gap }
                blocks[#blocks + 1] = { widget = note, height = nh, gap = l.note_label_gap }
                content_height = content_height + gap + lh + l.note_label_gap + nh
            end
            if content_height > l.body.h - l.body_padding * 2 then return false, "layout" end
        end
        canvas = draw:canvas(l.width, l.height)
        rect(0, 0, l.width, l.height, 246)
        rect(l.paper.x, l.paper.y, l.paper.w, l.paper.h, 255)
        border(l.paper, 184)
        local brand = text("留句  /  LIUJU", l.label.w, l.label_size, { gray = 112 })
        brand:paintTo(canvas, l.label.x, l.label.y)
        if entry then
            cover(l.cover)
            title(book.title, l.title, l.title_size, "left")
            local x = l.divider.x
            while x < l.divider.x + l.divider.w do
                rect(x, l.divider.y, math.min(l.dash, l.divider.x + l.divider.w - x), l.rule, 164)
                x = x + l.dash + l.dash_gap
            end
            local y = l.body.y + math.floor((l.body.h - content_height) / 2)
            for _, block in ipairs(blocks) do
                y = y + block.gap
                block.widget:paintTo(canvas, l.body.x + (block.x or 0), y)
                y = y + block.height
            end
            rect(l.footer.x, l.footer.y, l.p(40), l.rule, 112)
            if entry.date ~= "" then
                local date = text(entry.date, l.footer.w, l.date_size, { gray = 100 })
                date:paintTo(canvas, l.footer.x, l.footer.y + l.p(21))
            end
        else
            local box = { x = math.floor((l.width - l.p(565)) / 2),
                y = l.p(220), w = l.p(565), h = l.p(805) }
            cover(box)
            title(book.title, { x = l.body.x, y = l.p(1080),
                w = l.body.w, h = l.p(165) }, l.title_size, "center")
        end
        local written, err = canvas:writePNG(filename)
        if not written then return nil, "write: " .. tostring(err) end
        return true
    end)
    for _, widget in ipairs(resources) do if widget then pcall(widget.free, widget) end end
    if canvas then pcall(canvas.free, canvas) end
    if not ok then return nil, tostring(success) end
    return success, reason
end
return Renderer
