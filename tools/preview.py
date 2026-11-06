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
        self.fonts, self.canvases, self.widgets = {}, {}, {}
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
        max_height = options["max_height"]
        visible = min(len(lines), max(1, math.floor(max_height / line_height))) if max_height else len(lines)
        height = line_height * visible
        key = self.next_id()
        gray = 28 if options["gray"] is None else int(options["gray"])
        background = 255 if options["bgcolor"] is None else int(options["bgcolor"])
        self.widgets[key] = (lines[:visible], font, line_height, int(width), options["align"], gray, background)
        return key, height, len(lines), visible

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

    def circle(self, canvas, x, y, radius, gray):
        ImageDraw.Draw(self.canvases[canvas]).ellipse(
            (x - radius, y - radius, x + radius, y + radius), fill=gray)

    def background(self, canvas, asset, width, height):
        with Image.open(ROOT / "assets" / asset) as image:
            scaled = image.convert("L").resize((width, height), Image.Resampling.LANCZOS)
            self.canvases[canvas].paste(scaled)

    def save(self, canvas, path):
        self.canvases[canvas].save(path, format="PNG")
        return True


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
    local id,height,lines,visible=py_text(value,width,size,options or {})
    return {getSize=function()return{h=height}end,
        getAllLineCount=function()return lines end,
        getVisLineCount=function()return visible end,
        paintTo=function(_,canvas,x,y)py_paint_text(id,canvas.id,x,y)end,
        free=function()py_free_text(id)end}
end
function draw:circle(canvas,x,y,radius,gray)
    py_circle(canvas.id,x,y,radius,gray)
end
function draw:background(canvas,asset,w,h)
    py_background(canvas.id,asset,w,h)
end
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", type=Path, default=Path("/System/Library/Fonts/STHeiti Light.ttc"))
    parser.add_argument("--bold-font", type=Path, default=Path("/System/Library/Fonts/STHeiti Medium.ttc"))
    parser.add_argument("--output", type=Path, default=ROOT / "dist" / "previews")
    args = parser.parse_args()
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    lua = LuaRuntime(unpack_returned_tuples=True)
    painter = Painter(lua, args.font, args.bold_font)
    functions = {
        "hash": lambda value: hashlib.sha256(value.encode()).hexdigest(),
        "canvas": painter.canvas, "rect": painter.rect, "text": painter.text,
        "paint_text": painter.paint_text, "save": painter.save,
        "circle": painter.circle, "background": painter.background,
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
    entry = lua.table_from({
        "text": "读到喜欢的句子，就停一会儿。\n让书里的光，\n慢慢照进自己的生活。",
        "note": "",
        "date": "2026.11.06",
    })
    render = lua.eval("""function(book,entry,path)
        local ok,why=renderer:render(book,entry,path,1072,1448)
        if not ok then error(why or "render failed") end
    end""")
    styles = [
        ("classic", "半露 CD · 默认"),
        ("calendar", "白底日期卡"),
        ("dark", "纯色深灰卡"),
    ]
    width, height, gap = 350, 473, 22
    sheet = Image.new("RGB", (len(styles) * (width + gap) + gap, height + 80), "#e9e9e9")
    draw = ImageDraw.Draw(sheet)
    for index, (style, label) in enumerate(styles):
        path = out / f"{style}.png"
        render(lua.table_from({"title": "慢读的日子", "style": style}), entry, str(path))
        x = gap + index * (width + gap)
        draw.text((x, 16), label, font=painter.font(20, True), fill="#242424")
        with Image.open(path) as image:
            sheet.paste(image.resize((width, height), Image.Resampling.LANCZOS), (x, 48))
    sheet.save(out / "wallpaper-styles.png", optimize=True)
    print("Generated production-renderer desktop proofs:", out)


if __name__ == "__main__":
    main()
