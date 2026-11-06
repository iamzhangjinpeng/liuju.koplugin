-- Measurements follow the three bundled Yiyan templates.
local Layout = {
    STYLES = {
        { id = "classic", asset = "lyrics-background.png" },
        { id = "calendar", asset = "date-card-background.png" },
        { id = "dark", asset = "dark-card-background.png" },
    },
}

function Layout.style(value)
    for _, style in ipairs(Layout.STYLES) do
        if value == style.id then return style end
    end
    return Layout.STYLES[1]
end

local function round(value) return math.floor(value + 0.5) end

function Layout.for_screen(width, height, style)
    local sx, sy = width / 1072, height / 1448
    local scale = math.min(sx, sy)
    local function p(n) return math.max(1, round(n * scale)) end
    local function box(x, y, w, h, size, line_height)
        return { x = round(x * sx), y = round(y * sy), w = round(w * sx),
            h = round(h * sy), size = p(size), line_height = line_height }
    end
    local l = { width = width, height = height, p = p, fg = 17, bg = 255, muted = 102 }
    if style == "classic" then
        local margin = round(width * 0.112)
        local footer_y = round(height * 0.9)
        local footer_height = height - footer_y
        local radius = p(79)
        local inset = p(23)
        local x = margin + 2 * radius + inset
        local w = width - inset - x
        l.footer = { y = footer_y, h = footer_height }
        l.disc = { x = margin + radius, y = footer_y, radius = radius }
        l.body = { x = margin, y = round(height * 0.155), w = width - 2 * margin,
            h = round(height * 0.49), size = p(48), line_height = 0.65 }
        l.title = { x = x, y = footer_y + round(footer_height * 0.27), w = w,
            h = round(footer_height * 0.46), size = p(30), align = "center" }
        return l
    end
    if style == "calendar" then
        l.body = box(149, 465, 773, 570, 48, 0.60)
        l.month = box(145, 210, 240, 145, 100, 0.04)
        l.month.min_size = p(76)
        l.day = box(391, 221, 70, 62, 47, 0.10)
        l.weekday = box(464, 229, 181, 58, 32, 0.15)
        l.title = box(287, 1120, 555, 56, 39, 0.12)
        l.subtitle = box(288, 1181, 554, 49, 28, 0.17)
        return l
    end
    l.fg, l.bg, l.muted = 247, 68, 184
    l.body = box(149, 631, 773, 677, 51, 0.74)
    l.body.bottom = round(1033 * sy)
    l.date = box(147, 198, 510, 58, 31, 0.16)
    l.title = box(296, 1119, 555, 56, 39, 0.12)
    l.subtitle = box(297, 1180, 554, 49, 28, 0.17)
    return l
end

return Layout
