#!/usr/bin/env python3
"""Convert indented /****\\ |* ... \\****/ block comments back to // comments.

Only touches block comments that DON'T start at column 0.
Column-0 block comments are left as-is.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIRS = [ROOT / "src", ROOT / "tests"]

OPEN_RE  = re.compile(r'^(\s+)/\*{10,}\\$')
CLOSE_RE = re.compile(r'^\s*\\\*{10,}/$')


def convert_file(path: Path) -> int:
    lines = path.read_text().split("\n")
    out = []
    converted = 0
    i = 0

    while i < len(lines):
        m = OPEN_RE.match(lines[i])
        if m:
            indent = m.group(1)
            block_start = i
            i += 1
            body_lines = []
            while i < len(lines):
                if CLOSE_RE.match(lines[i]):
                    i += 1
                    break
                s = lines[i].lstrip()
                if s.startswith("|* "):
                    body_lines.append(s[3:])
                elif s.startswith("|*"):
                    body_lines.append(s[2:])
                else:
                    body_lines.append(s)
                i += 1

            # Emit as // comments
            for bl in body_lines:
                if bl:
                    bl = bl.replace("/ *", "/*").replace("* /", "*/")
                    out.append(indent + "// " + bl)
                else:
                    out.append(indent + "//")
            converted += 1
        else:
            out.append(lines[i])
            i += 1

    if converted > 0:
        path.write_text("\n".join(out))
    return converted


def main() -> None:
    total_files = 0
    total_blocks = 0

    for d in DIRS:
        for ext in ("*.h", "*.m"):
            for path in sorted(d.rglob(ext)):
                n = convert_file(path)
                if n > 0:
                    total_files += 1
                    total_blocks += n
                    print(f"  {path.relative_to(ROOT)}: {n} blocks")

    print(f"\nConverted {total_blocks} indented blocks in {total_files} files.")


if __name__ == "__main__":
    main()
