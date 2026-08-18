"""Create SysInput's checked-in PNG and multi-size Windows icon."""

from pathlib import Path
import shutil
import sys

from PIL import Image, IcoImagePlugin


SIZES = (16, 20, 24, 32, 48, 64, 128, 256)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_icon.py SOURCE.png RESOURCE_DIRECTORY")
    source = Path(sys.argv[1]).resolve()
    resource_dir = Path(sys.argv[2]).resolve()
    resource_dir.mkdir(parents=True, exist_ok=True)

    checked_in_source = resource_dir / "sysinput-source.png"
    if source != checked_in_source:
        shutil.copyfile(source, checked_in_source)

    with Image.open(checked_in_source) as image:
        rgba = image.convert("RGBA")
        icon_path = resource_dir / "sysinput.ico"
        rgba.save(icon_path, format="ICO", sizes=[(size, size) for size in SIZES])

    with icon_path.open("rb") as stream:
        embedded = IcoImagePlugin.IcoFile(stream).sizes()
    expected = {(size, size) for size in SIZES}
    if embedded != expected:
        raise SystemExit(f"ICO validation failed: expected {sorted(expected)}, got {sorted(embedded)}")
    print(f"Generated {icon_path} with {len(embedded)} sizes")


if __name__ == "__main__":
    main()
