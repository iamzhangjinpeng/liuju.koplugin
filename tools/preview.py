"""Render desktop design proofs through the production Lua renderer.

The bridge substitutes font rasterization, image scaling and PNG encoding.
Coordinates, fixed sizes, overflow decisions and content layout come from
liuju_render.lua / liuju_layout.lua. KOReader font shaping still needs a device.
"""
import argparse
import hashlib
import math
from pathlib import Path

from lupa.lua51 import LuaRuntime
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]


class Painter:
    def __init__(self, lua, font, bold_font):
        self.lua = lua
        self.font_path, self.bold_path = font, bold_font
        self.fonts, self.canvases, self.widgets, self.covers = {}, {}, {}, {}
        self.counter = 0

    def next_id(self):
        self.counter += 1
        return self.counter

    def font(self, size, bold=False):
        key = (int(round(size)), bool(bold))
        if key not in self.fonts:
            self.fonts[key] = ImageFont.truetype(str(self.bold_path if bold else self.font_path), max(1, key[0]))
        return self.fonts[key]

    def canvas(self, width, height):
        key = self.next_id()
        self.canvases[key] = Image.new("L", (int(width), int(height)), 255)
        return key

    def rect(self, key, x, y, width, height, gray):
        if width > 0 and height > 0:
            ImageDraw.Draw(self.canvases[key]).rectangle(
                (int(x), int(y), int(x + width - 1), int(y + height - 1)), fill=int(gray))

    def text(self, value, width, size, options):
        font = self.font(size, options["bold"])
        lines = []
        for paragraph in value.split("\n"):
            line = ""
            for char in paragraph:
                if line and font.getlength(line + char) > width:
                    lines.append(line)
                    line = char
                else:
                    line += char
            lines.append(line)
        line_height = math.floor(float(size) * (1 + float(options["line_height"] or 0.48)) + 0.5)
        height = line_height * len(lines)
        key = self.next_id()
        gray = 28 if options["gray"] is None else int(options["gray"])
        background = 255 if options["bgcolor"] is None else int(options["bgcolor"])
        self.widgets[key] = (lines, font, line_height, int(width), options["align"], gray, background)
        return key, height, len(lines)

    def paint_text(self, key, canvas, x, y):
        lines, font, line_height, width, align, gray, background = self.widgets[key]
        draw = ImageDraw.Draw(self.canvases[canvas])
        draw.rectangle((x, y, x + width - 1, y + line_height * len(lines) - 1), fill=background)
        for i, line in enumerate(lines):
            advance = font.getlength(line)
            dx = (width - advance) / 2 if align == "center" else width - advance if align == "right" else 0
            box = font.getbbox(line or "字")
            dy = (line_height - (box[3] - box[1])) / 2 - box[1]
            draw.text((x + dx, y + i * line_height + dy), line, font=font, fill=gray)

    def paint_cover(self, canvas, key, x, y, width, height):
        image = self.covers[key].resize((int(width), int(height)), Image.Resampling.LANCZOS)
        self.canvases[canvas].paste(image, (int(x), int(y)))
        return True

    def cover_size(self, key):
        image = self.covers.get(key)
        return image.size if image else (None, None)

    def save(self, canvas, path):
        self.canvases[canvas].save(path, format="PNG")
        return True

    def cover_fixture(self):
        image = Image.new("L", (420, 600), 228)
        draw = ImageDraw.Draw(image)
        draw.rectangle((29, 29, 390, 570), outline=110, width=2)
        draw.rectangle((45, 380, 375, 555), fill=84)
        for n in range(5):
            draw.line((60, 405 + n * 29, 355, 475 + n * 12), fill=143, width=2)
        draw.text((62, 105), "慢读的日子", font=self.font(49, True), fill=35)
        draw.text((65, 188), "在书页之间，\n留一点时间给自己。", font=self.font(26), fill=78, spacing=12)
        key = self.next_id()
        self.covers[key] = image
        return key


BRIDGE = """
package.loaded["ffi/sha2"]={sha256=function(value)return py_hash(value)end}
draw={}
function draw:canvas(w,h)
    local id=py_canvas(w,h)
    return {id=id,writePNG=function(_,path)return py_save(id,path)end,
        free=function()py_free_canvas(id)end}
end
function draw:rect(canvas,x,y,w,h,gray)py_rect(canvas.id,x,y,w,h,gray)end
function draw:text(value,width,size,options)
    local id,height,lines=py_text(value,width,size,options or {})
    return {getSize=function()return{h=height}end,
        getAllLineCount=function()return lines end,
        paintTo=function(_,canvas,x,y)py_paint_text(id,canvas.id,x,y)end,
        free=function()py_free_text(id)end}
end
function draw:cover(canvas,image,rect)
    return py_cover(canvas.id,image,rect.x,rect.y,rect.w,rect.h)
end
function draw:cover_size(image)
    return py_cover_size(image)
end
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", type=Path, default=Path("/System/Library/Fonts/STHeiti Light.ttc"))
    parser.add_argument("--bold-font", type=Path, default=Path("/System/Library/Fonts/STHeiti Medium.ttc"))
    args = parser.parse_args()
    out = ROOT / "previews"
    out.mkdir(exist_ok=True)
    lua = LuaRuntime(unpack_returned_tuples=True)
    painter = Painter(lua, args.font, args.bold_font)
    functions = {
        "hash": lambda value: hashlib.sha256(value.encode()).hexdigest(),
        "canvas": painter.canvas, "rect": painter.rect, "text": painter.text,
        "paint_text": painter.paint_text, "cover": painter.paint_cover, "save": painter.save,
        "cover_size": painter.cover_size,
        "free_canvas": lambda key: painter.canvases.pop(key, None),
        "free_text": lambda key: painter.widgets.pop(key, None),
    }
    for name, value in functions.items():
        lua.globals()["py_" + name] = value
    lua.execute(BRIDGE)
    lua.globals().ROOT = str(ROOT)
    lua.execute("""
        core=dofile(ROOT.."/liuju_core.lua")
        layout=dofile(ROOT.."/liuju_layout.lua")
        renderer=dofile(ROOT.."/liuju_render.lua").new(core,layout,draw)
    """)
    cover = painter.cover_fixture()
    book = lua.table_from({"title": "慢读的日子", "cover": cover})
    short = "把一句喜欢的话，留在合上书后的片刻。"
    medium = "读书的时候，我们偶尔会停下来。让一句话多停留片刻，让自己的想法也在书页之外，找到一个安静的位置。"
    seed = "慢慢读一本书，也是在给自己留下思考的空隙。那些被划下的句子，会在另一个平凡的日子里重新发亮。此刻不必急着翻页，可以停下来，听一听心里刚刚生出的回声。让阅读继续，也让生活保持从容。"
    boundary = seed[:79] + "。"
    samples = [
        ("short", short, "", "短摘录"),
        ("medium", medium, "", "中等摘录"),
        ("80-characters", boundary, "", "80 字边界"),
        ("with-note", "有些句子，需要在生活里再读一遍。", "记下今天的感受，留给未来某次偶然的重逢。", "原文与批注"),
    ]
    rendered = []
    render = lua.eval("""function(book,entry,path)
        local ok,why=renderer:render(book,entry,path,1072,1448)
        if not ok then error(why or "render failed") end
        return true
    end""")
    for name, quote, note, label in samples:
        path = out / f"{name}.png"
        entry = lua.table_from({"text": quote, "note": note, "date": "2026.11.03"})
        result = render(book, entry, str(path))
        if result is not True:
            raise RuntimeError((name, result))
        rendered.append((path, f"{label} · {len(quote + note)} 字"))
    fallback = out / "cover-fallback.png"
    assert render(book, None, str(fallback)) is True
    missing = out / "missing-cover.png"
    assert render(lua.table_from({"title": "一本没有封面的书"}), None, str(missing)) is True

    assert render(lua.table_from({"title": "一本没有封面的书"}),
                  lua.table_from({"text": short, "note": "", "date": "2026.11.03"}),
                  str(out / "missing-cover-with-quote.png")) is True
    assert render(lua.table_from({"title": "慢读的日子：关于散步、停留、阅读和日常生活的温柔观察与私人记录", "cover": cover}),
                  lua.table_from({"text": medium, "note": "", "date": "2026.11.03"}),
                  str(out / "long-title.png")) is True
    for name, items, thumb_w in [
        ("design-comparison.png", [(out / "previous-receipt.png", "原小票布局"), (out / "medium.png", "新分享海报布局")], 402),
        ("selected-gallery.png", rendered, 268),
    ]:
        thumb_h = round(1448 / 1072 * thumb_w)
        sheet = Image.new("RGB", (len(items) * (thumb_w + 24) + 24, thumb_h + 100), "#e8e8e8")
        draw = ImageDraw.Draw(sheet)
        for i, (path, label) in enumerate(items):
            x = 24 + i * (thumb_w + 24)
            sheet.paste(Image.open(path).resize((thumb_w, thumb_h), Image.Resampling.LANCZOS).convert("RGB"), (x, 18))
            draw.text((x + 4, thumb_h + 40), label, font=painter.font(18), fill="#343434")
        sheet.save(out / name)
    print("Generated production-renderer desktop proofs:", out)


if __name__ == "__main__":
    main()
