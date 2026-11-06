"""Build two original EPUBs for the manual KPW4 acceptance checklist."""
from html import escape
from io import BytesIO
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "dist" / "device-fixtures"


def cover():
    image = Image.new("L", (420, 600), 235)
    draw = ImageDraw.Draw(image)
    draw.rectangle((25, 25, 394, 574), outline=90, width=3)
    draw.text((145, 155), "A", font=ImageFont.load_default(size=180), fill=35)
    draw.text((77, 426), "LIUJU / BOOK A", font=ImageFont.load_default(size=30), fill=60)
    output = BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def build(name, title, sections, with_cover):
    items = "".join(f"<h2>{escape(label)}</h2><p>{escape(body)}</p>" for label, body in sections)
    text = f'''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN"><head>
<title>{title}</title><style>body{{margin:1em;line-height:1.8}}p{{margin-bottom:2em}}</style>
</head><body><h1>{title}</h1><p>请仅划线每个标题下面的正文，不包含标题。</p>{items}</body></html>'''
    cover_item = '<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>' if with_cover else ""
    cover_meta = '<meta name="cover" content="cover"/>' if with_cover else ""
    opf = f'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">urn:liuju:test:{name}</dc:identifier>
<dc:title>{title}</dc:title><dc:language>zh-CN</dc:language><dc:creator>留句测试</dc:creator>
<meta property="dcterms:modified">2026-11-03T00:00:00Z</meta>{cover_meta}
</metadata><manifest>
<item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{cover_item}
</manifest><spine><itemref idref="text"/></spine></package>'''
    nav = f'''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head><body><nav epub:type="toc"><ol>
<li><a href="text.xhtml">{title}</a></li></ol></nav></body></html>'''
    container = '''<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'''
    output = OUT / f"{name}.epub"
    for xml in (text, opf, nav, container):
        ET.fromstring(xml)
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as package:
        package.writestr("mimetype", "application/epub+zip", compress_type=ZIP_STORED)
        package.writestr("META-INF/container.xml", container)
        package.writestr("OEBPS/content.opf", opf)
        package.writestr("OEBPS/text.xhtml", text)
        package.writestr("OEBPS/nav.xhtml", nav)
        if with_cover:
            package.writestr("OEBPS/cover.png", cover())
    return output


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    seed = "阅读使我们慢下来也让平凡的一天多出一个可以停留的地方"
    sections = [("短摘录", "这是甲书的句子，锁屏应当只展示当前书的内容。")]
    for count in (79, 80, 81):
        body = (seed * 5)[:count - 1] + "。"
        assert len(body) == count
        sections.append((f"{count} 字边界", body))
    sections.append(("给这段文字添加一条短批注", "原文与批注应合并计数，并且完整展示。"))
    files = [build("liuju-test-a", "留句测试甲", sections, True),
             build("liuju-test-b-no-cover", "留句测试乙", [("另一本文字", "这是乙书。换书之后，不应再次看到甲书的摘录。")], False)]
    notes = OUT / "使用说明.txt"
    notes.write_text("在甲书中划线短句、79/80/81字段落，再切换乙书并划线。\n默认80字下，81字段落不生成。乙书没有封面，也应能用标注生成小票。\n具体步骤见仓库 docs/DEVICE-VALIDATION.md。\n")
    archive = ROOT / "dist" / "liuju-device-fixtures.zip"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED) as package:
        for file in [*files, notes]:
            package.write(file, file.name)
    print(archive)


if __name__ == "__main__":
    main()
