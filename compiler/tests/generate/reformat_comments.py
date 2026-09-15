#!/usr/bin/env python3
"""Reformat consecutive // comment blocks in .h/.m files to the
/****************************************************************************\\
|* ...
\\****************************************************************************/
block style.

Runs in-place on all .h and .m files under src/ and tests/.
Idempotent — already-converted blocks are left alone.

Rules:
  - A "block" is 2+ consecutive lines whose stripped form starts with //
  - Single // lines are left as-is
  - Lines inside string literals are not affected (we only look at
    leading whitespace + //)
  - The indentation of the opening /*** line matches the indentation
    of the first // line in the block
  - Inline trailing // comments (code before the //) are NOT touched
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIRS = [ROOT / "src", ROOT / "tests"]

BANNER_WIDTH = 76  # characters between /  and  \ (or \ and /)
OPEN  = "/" + "*" * BANNER_WIDTH + "\\"
CLOSE = "\\" + "*" * BANNER_WIDTH + "/"


def is_pure_comment_line(line: str) -> bool:
    """True if the line is ONLY a // comment (no code before it)."""
    stripped = line.lstrip()
    return stripped.startswith("//")


def strip_comment_prefix(line: str) -> str:
    """Remove the leading // or /// (and optional single space) from a comment line."""
    stripped = line.lstrip()
    if stripped.startswith("///"):
        after = stripped[3:]  # remove ///
    else:
        after = stripped[2:]  # remove //
    if after.startswith(" "):
        after = after[1:]  # remove the single space after the prefix
    return after


def reformat_file(path: Path) -> int:
    """Reformat comment blocks in one file. Returns number of blocks converted."""
    lines = path.read_text().split("\n")
    out = []
    converted = 0
    i = 0

    while i < len(lines):
        # Check if this starts a run of 2+ consecutive // lines
        if is_pure_comment_line(lines[i]):
            # Collect the full run
            block_start = i
            while i < len(lines) and is_pure_comment_line(lines[i]):
                i += 1
            block_end = i  # exclusive

            # Convert if: 2+ consecutive lines, OR any line uses ///
            has_doc = any(lines[j].lstrip().startswith("///")
                         for j in range(block_start, block_end))
            if block_end - block_start >= 2 or has_doc:
                # Convert this block
                indent = " " * (len(lines[block_start]) - len(lines[block_start].lstrip()))
                out.append(indent + OPEN)
                for j in range(block_start, block_end):
                    text = strip_comment_prefix(lines[j])
                    # Escape /* and */ inside block comments to avoid nesting
                    text = text.replace("/*", "/ *").replace("*/", "* /")
                    out.append(indent + "|* " + text if text else indent + "|*")
                out.append(indent + CLOSE)
                converted += 1
            else:
                # Single // line — leave as-is
                for j in range(block_start, block_end):
                    out.append(lines[j])
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
                n = reformat_file(path)
                if n > 0:
                    total_files += 1
                    total_blocks += n
                    print(f"  {path.relative_to(ROOT)}: {n} blocks")

    print(f"\nConverted {total_blocks} blocks in {total_files} files.")


if __name__ == "__main__":
    main()
