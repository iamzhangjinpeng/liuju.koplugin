-- Coordinates are physical pixels, scaled from the KPW4 portrait canvas.
local Layout = {}
function Layout.for_screen(width, height)
    width, height = math.min(width, height), math.max(width, height)
    local scale = math.min(width / 1072, height / 1448)
    local function p(n) return math.floor(n * scale + 0.5) end
    local footer_y = height - p(224)
    local album_y = footer_y - p(140)
    local body_x, body_y = p(108), p(172)
    return {
        width = width, height = height, scale = scale, p = p,
        footer = { x = 0, y = footer_y, w = width, h = height - footer_y },
        album = { x = p(92), y = album_y, w = p(264), h = p(264) },
        cover = { x = p(104), y = album_y + p(12), w = p(240), h = p(240) },
        title = { x = p(404), y = footer_y + p(69), w = width - p(500), h = p(116) },
        label = { x = p(404), y = footer_y + p(25), w = width - p(500), h = p(30) },
        body = { x = body_x, y = body_y, w = width - body_x * 2,
            h = album_y - body_y - p(126) },
        quote_size = p(52), note_size = p(46), title_size = p(40),
        label_size = p(22), date_size = p(26), line_height = 0.55,
        note_gap = p(44), note_label_gap = p(16), body_padding = 0,
        date_gap = p(48), rule = math.max(1, p(1)), shadow = p(7),
    }
end
return Layout
