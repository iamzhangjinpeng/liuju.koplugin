-- Coordinates are physical pixels, scaled from the KPW4 portrait canvas.
local Layout = {}
function Layout.for_screen(width, height, cover_width, cover_height)
    width, height = math.min(width, height), math.max(width, height)
    local scale = math.min(width / 1072, height / 1448)
    local function p(n) return math.floor(n * scale + 0.5) end
    local footer_h = p(224)
    local footer_y = height - footer_h
    local album_x, frame = p(92), p(10)
    local album_size = p(264)
    local cover_size = album_size - frame * 2
    cover_width, cover_height = cover_width or 420, cover_height or 600
    local fit = cover_size / math.max(cover_width, cover_height)
    local cover_w = math.max(1, math.floor(cover_width * fit))
    local cover_h = math.max(1, math.floor(cover_height * fit))
    local album_w, album_h = cover_w + frame * 2, cover_h + frame * 2
    local album_y = footer_y - math.floor(album_h / 2)
    local title_gap, title_h = p(36), p(132)
    local title_x = album_x + album_w + title_gap
    local body_x, body_y = p(108), p(172)
    return {
        width = width, height = height, scale = scale, p = p,
        footer = { x = 0, y = footer_y, w = width, h = footer_h },
        album = { x = album_x, y = album_y, w = album_w, h = album_h },
        cover = { x = album_x + frame, y = album_y + frame, w = cover_w, h = cover_h },
        title = { x = title_x, y = footer_y + math.floor((footer_h - title_h) / 2),
            w = width - title_x - title_gap, h = title_h },
        body = { x = body_x, y = body_y, w = width - body_x * 2,
            h = footer_y - math.floor(album_size / 2) - body_y - p(126) },
        quote_size = p(52), note_size = p(46), title_size = p(44),
        label_size = p(22), date_size = p(26), line_height = 0.55,
        note_gap = p(44), note_label_gap = p(16), body_padding = 0,
        date_gap = p(48), rule = math.max(1, p(1)),
    }
end
return Layout
