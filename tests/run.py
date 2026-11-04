"""Run the Lua 5.1 regression suite using an isolated Lupa interpreter.

Install development dependencies: python -m pip install lupa pillow
No Kindle paths or network services are used by this runner.
"""
import hashlib
import os
from pathlib import Path
import stat
import tempfile

from lupa.lua51 import LuaRuntime
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def run():
    with tempfile.TemporaryDirectory(prefix="liuju-tests-") as scratch:
        lua = LuaRuntime(unpack_returned_tuples=True)

        def attrs(path, field=None, symlink=False):
            try:
                result = os.lstat(path) if symlink else os.stat(path)
            except OSError:
                return None
            kind = "link" if stat.S_ISLNK(result.st_mode) else "directory" if stat.S_ISDIR(result.st_mode) else "file"
            data = {"mode": kind, "size": result.st_size, "modification": result.st_mtime}
            return data.get(field) if field else lua.table_from(data)

        def write_png(path, width, height):
            Image.new("L", (int(width), int(height)), 255).save(path, format="PNG")
            return True

        def decode_png(path):
            try:
                with Image.open(path) as image:
                    image.load()
                    return image.size
            except OSError:
                return None, None

        def corrupt_png_data(path):
            path = Path(path)
            data = bytearray(path.read_bytes())
            assert data[37:41] == b"IDAT"
            data[41] ^= 255
            path.write_bytes(data)

        lua.globals().py_hash = lambda value: hashlib.sha256(value.encode("utf-8")).hexdigest()
        lua.globals().py_attrs = attrs
        lua.globals().py_list = lambda path: lua.table_from(os.listdir(path))
        lua.globals().py_mkdir = lambda path: Path(path).mkdir(parents=True, exist_ok=True)
        lua.globals().py_png = write_png
        lua.globals().py_decode_png = decode_png
        lua.globals().py_corrupt_png_data = corrupt_png_data
        lua.globals().TEST_ROOT = str(ROOT)
        lua.globals().SCRATCH = scratch
        lua.execute((ROOT / "tests" / "spec.lua").read_text())


if __name__ == "__main__":
    run()
