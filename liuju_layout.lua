-- Coordinates are physical pixels, scaled from the KPW4 portrait canvas.
local Layout = {}
function Layout.for_screen(width, height)
    width, height = math.min(width, height), math.max(width, height)
    local scale = math.min(width / 1072, height / 1448)
    local function p(n) return math.floor(n * scale + 0.5) end
    local ox, oy = math.floor((width - p(1072)) / 2), math.floor((height - p(1448)) / 2)
    local function box(x, y, w, h)
        return { x = ox + p(x), y = oy + p(y), w = p(w), h = p(h) }
    end
    return {
        width = width, height = height, scale = scale, p = p,
        paper = box(72, 66, 928, 1316),
        cover = box(146, 181, 180, 256),
        title = box(373, 207, 545, 189),
        label = box(146, 117, 772, 32),
        divider = box(146, 491, 772, 2),
        body = box(146, 548, 772, 602),
        footer = box(146, 1228, 772, 56),
        quote_size = p(46), note_size = p(42), title_size = p(36),
        label_size = p(22), date_size = p(26), line_height = 0.48,
        note_gap = p(34), note_label_gap = p(12), body_padding = p(20),
        rule = math.max(1, p(1)), dash = p(9), dash_gap = p(9),
    }
end
return Layout
