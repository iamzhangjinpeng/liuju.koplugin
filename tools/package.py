"""Create a KOReader installation ZIP containing only the plugin runtime."""
import hashlib
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r'version\s*=\s*"([^"]+)"', (ROOT / "_meta.lua").read_text()).group(1)
RUNTIME_FILES = (
    "_meta.lua",
    "liuju_core.lua",
    "liuju_draw.lua",
    "liuju_layout.lua",
    "liuju_policy.lua",
    "liuju_render.lua",
    "liuju_store.lua",
    "main.lua",
    "assets/lyrics-background.png",
    "assets/date-card-background.png",
    "assets/dark-card-background.png",
)


def main():
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    archive = output / f"liuju.koplugin-v{VERSION}.zip"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as package:
        for filename in RUNTIME_FILES:
            info = ZipInfo(f"liuju.koplugin/{filename}", (2026, 11, 3, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, (ROOT / filename).read_bytes())
    with ZipFile(archive) as package:
        assert package.testzip() is None
        assert package.namelist() == [f"liuju.koplugin/{name}" for name in RUNTIME_FILES]
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    print(f"{archive}\nSHA256 {digest}\n{len(RUNTIME_FILES)} install files")


if __name__ == "__main__":
    main()
