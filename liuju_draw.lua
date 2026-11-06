-- KOReader-specific drawing adapter. The renderer also accepts a desktop
-- adapter for repeatable design previews without changing the layout code.
local BB = require("ffi/blitbuffer")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local RenderImage = require("ui/renderimage")
local base = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
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
        height = options.max_height, height_adjust = options.max_height ~= nil,
        bold = options.bold, line_height = options.line_height or 0.48,
        alignment = options.align or "left", alignment_strict = true,
        justified = false, auto_para_direction = true,
        fgcolor = BB.Color8(options.gray or 28),
        bgcolor = options.bgcolor ~= nil and BB.Color8(options.bgcolor) or BB.COLOR_WHITE,
    }
end

function Draw:circle(canvas, x, y, radius, gray)
    canvas:paintCircle(x, y, radius, BB.Color8(gray))
end

function Draw:background(canvas, asset, width, height)
    local source = assert(RenderImage:renderImageFile(base .. "assets/" .. asset, false),
        "Cannot load wallpaper background")
    local scaled
    local ok, err = pcall(function()
        scaled = assert(RenderImage:scaleBlitBuffer(source, width, height, false),
            "Cannot scale wallpaper background")
        canvas:blitFrom(scaled, 0, 0, 0, 0, width, height)
    end)
    if scaled and scaled ~= source then scaled:free() end
    source:free()
    if not ok then error(err, 0) end
end

return Draw
