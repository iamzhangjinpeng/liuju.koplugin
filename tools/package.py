"""Create the directly installable release-candidate ZIP, without dev files."""
import hashlib
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r'version\s*=\s*"([^"]+)"', (ROOT / "_meta.lua").read_text()).group(1)
FILES = sorted([ROOT / "_meta.lua", ROOT / "main.lua", ROOT / "README.md",
                ROOT / "CHANGELOG.md", *ROOT.glob("liuju_*.lua")])


def main():
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    archive = output / f"liuju.koplugin-v{VERSION}.zip"
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as package:
        for source in FILES:
            info = ZipInfo(f"liuju.koplugin/{source.name}", (2026, 11, 3, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, source.read_bytes())
    with ZipFile(archive) as package:
        assert package.testzip() is None
        names = package.namelist()
        assert "liuju.koplugin/main.lua" in names and "liuju.koplugin/_meta.lua" in names
        assert len(names) == len(FILES)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
    print(f"{archive}\nSHA256 {digest}\n{len(FILES)} install files")


if __name__ == "__main__":
    main()
