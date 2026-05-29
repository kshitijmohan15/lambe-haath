"""CLI entry: read a bundle spec from stdin, write the output to --output.

The Zig daemon spawns this as a one-shot subprocess for export jobs.

Stdin JSON (single line):
    {
      "format": "md" | "docx",
      "mode": "single" | "bundle",
      "items": [{"name": "<prompt_name>", "md_path": "/abs/path/to/file.md"}, ...]
    }

For mode=single: items has exactly one entry; output_path receives the
single .md or .docx file (no zip).

For mode=bundle: items has 1..N entries; output_path receives a .zip
containing one <name>.<ext> per item.

Exit 0 on success, non-zero with stderr on failure.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import zipfile
from pathlib import Path

from agents.exporter.convert import md_to_docx


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="agents.exporter")
    parser.add_argument("--output", required=True, help="Absolute output path")
    args = parser.parse_args(argv)

    try:
        spec = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"exporter: invalid stdin JSON: {e}", file=sys.stderr)
        return 2

    fmt = spec.get("format")
    if fmt not in ("md", "docx"):
        print(f"exporter: format must be 'md' or 'docx' (got {fmt!r})", file=sys.stderr)
        return 2
    mode = spec.get("mode")
    if mode not in ("single", "bundle"):
        print(f"exporter: mode must be 'single' or 'bundle' (got {mode!r})", file=sys.stderr)
        return 2
    items = spec.get("items") or []
    if not items:
        print("exporter: no items to export", file=sys.stderr)
        return 2
    if mode == "single" and len(items) != 1:
        print(f"exporter: mode=single requires exactly one item (got {len(items)})", file=sys.stderr)
        return 2

    output_path = Path(args.output)
    try:
        if mode == "single":
            _emit_single(items[0], fmt, output_path)
        else:
            _emit_bundle(items, fmt, output_path)
    except Exception as e:
        print(f"exporter: {e}", file=sys.stderr)
        return 1
    return 0


def _emit_single(item: dict, fmt: str, output_path: Path) -> None:
    md_path = Path(item["md_path"])
    if fmt == "md":
        output_path.write_bytes(md_path.read_bytes())
    else:  # docx
        md_to_docx(md_path.read_text(encoding="utf-8"), output_path)


def _emit_bundle(items: list[dict], fmt: str, output_path: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="exporter-") as tmpdir:
        tmp = Path(tmpdir)
        converted: list[tuple[str, Path]] = []
        for item in items:
            name = item["name"]
            md_path = Path(item["md_path"])
            if fmt == "md":
                # Copy as-is to preserve the source bytes.
                out = tmp / f"{name}.md"
                out.write_bytes(md_path.read_bytes())
                converted.append((f"{name}.md", out))
            else:
                out = tmp / f"{name}.docx"
                md_to_docx(md_path.read_text(encoding="utf-8"), out)
                converted.append((f"{name}.docx", out))

        with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for arcname, path in converted:
                z.write(path, arcname=arcname)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
