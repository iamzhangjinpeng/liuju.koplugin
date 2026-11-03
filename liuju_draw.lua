-- KOReader-specific drawing adapter. The renderer also accepts a desktop
-- adapter for repeatable design previews without changing the layout code.
local BB = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Screen = require("device").screen
local Draw = {}

function Draw:signature()
    return tostring(Font.fontmap.cfont) .. ":" .. tostring(Screen:scaleBySize(1000))
end

function Draw:canvas(w, h)
    return BB.new(w, h, BB.TYPE_BB8)
end

function Draw:rect(canvas, x, y, w, h, gray)
    canvas:paintRect(x, y, w, h, BB.Color8(gray))
end

function Draw:text(text, width, pixels, options)
    options = options or {}
    -- Font:getFace applies screen scaling itself; the layout already uses
    -- physical pixels. Compensate here instead of scaling twice on KPW4.
    local factor = Screen:scaleBySize(1000) / 1000
    local face = assert(Font:getFace("cfont", pixels / factor), "No UI font available")
    return TextBoxWidget:new{
        text = text, width = width, face = face,
        bold = options.bold, line_height = options.line_height or 0.48,
        alignment = options.align or "left", alignment_strict = true,
        justified = false, auto_para_direction = true,
        fgcolor = BB.Color8(options.gray or 28),
        bgcolor = options.bgcolor ~= nil and BB.Color8(options.bgcolor) or BB.COLOR_WHITE,
    }
end

function Draw:cover(canvas, image, rect)
    if not image then return false end
    local iw, ih = image:getWidth(), image:getHeight()
    if iw <= 0 or ih <= 0 then return false end
    local scale = math.min(rect.w / iw, rect.h / ih)
    local width, height = math.max(1, math.floor(iw * scale)), math.max(1, math.floor(ih * scale))
    local widget = ImageWidget:new{
        image = image, image_disposable = false,
        width = width, height = height, scale_factor = 0,
    }
    local ok, err = pcall(function()
        widget:paintTo(canvas, rect.x + math.floor((rect.w - width) / 2),
            rect.y + math.floor((rect.h - height) / 2))
    end)
    widget:free()
    if not ok then error(err) end
    return true
end

return Draw
