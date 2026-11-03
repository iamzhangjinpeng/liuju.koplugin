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
    local function title(value, box, size, align, colors)
        colors = colors or {}
        local options = { bold = true, align = align, gray = colors.gray or 28,
            bgcolor = colors.bgcolor or 255, line_height = 0.35 }
        local value_now = self.core.shorten(value, 48)
        local widget, h = text(value_now, box.w, size, options)
        while h > box.h do
            local chars = self.core.characters(value_now)
            if not chars or #chars <= 2 then return end
            release(widget)
            value_now = self.core.shorten(value_now, #chars - 1)
            widget, h = text(value_now, box.w, size, options)
        end
        widget:paintTo(canvas, box.x, box.y + math.floor((box.h - h) / 2))
    end
    local function cover(box)
        if draw:cover(canvas, book.cover, box) then return end
        rect(box.x, box.y, box.w, box.h, 249)
        border(box, 168)
        local inset = l.p(16)
        title(book.title, { x = box.x + inset, y = box.y + inset,
            w = box.w - inset * 2, h = box.h - inset * 2 }, l.p(25), "center", { bgcolor = 249 })
    end
    local ok, success, reason = pcall(function()
        local blocks, content_height = {}, 0
        if entry then
            if entry.text ~= "" then
                local widget, h = text(entry.text, l.body.w, l.quote_size, { line_height = l.line_height })
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
                            local candidate, ch = text(entry.text, middle, l.quote_size, { line_height = l.line_height })
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
                blocks[#blocks + 1] = { widget = widget, height = h, gap = 0 }
                content_height = h
            end
            if entry.note ~= "" then
                local gap = content_height > 0 and l.note_gap or 0
                local label, lh = text("笔记", l.body.w, l.label_size, { gray = 110 })
                local note, nh = text(entry.note, l.body.w, l.note_size, { line_height = l.line_height })
                blocks[#blocks + 1] = { widget = label, height = lh, gap = gap }
                blocks[#blocks + 1] = { widget = note, height = nh, gap = l.note_label_gap }
                content_height = content_height + gap + lh + l.note_label_gap + nh
            end
            if content_height > l.body.h - l.body_padding * 2 then return false, "layout" end
        end
        canvas = draw:canvas(l.width, l.height)
        rect(0, 0, l.width, l.height, 255)
        rect(l.footer.x, l.footer.y, l.footer.w, l.footer.h, 0)
        rect(l.album.x + l.shadow, l.album.y + l.shadow, l.album.w, l.album.h, 112)
        rect(l.album.x, l.album.y, l.album.w, l.album.h, 255)
        border(l.album, 198)
        cover(l.cover)
        local brand = text("留句  /  LIUJU", l.label.w, l.label_size, { gray = 170, bgcolor = 0 })
        brand:paintTo(canvas, l.label.x, l.label.y)
        title(book.title, l.title, l.title_size, "left", { gray = 255, bgcolor = 0 })
        if entry then
            local y = l.body.y
            for _, block in ipairs(blocks) do
                y = y + block.gap
                block.widget:paintTo(canvas, l.body.x, y)
                y = y + block.height
            end
            if entry.date ~= "" then
                local date = text(entry.date, l.body.w, l.date_size, { gray = 116 })
                date:paintTo(canvas, l.body.x, y + l.date_gap)
            end
        else
            local reading, rh = text("正在阅读", l.body.w, l.label_size, { gray = 116 })
            reading:paintTo(canvas, l.body.x, l.body.y)
            title(book.title, { x = l.body.x, y = l.body.y + rh + l.p(45),
                w = l.body.w, h = l.p(260) }, l.quote_size, "left")
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
