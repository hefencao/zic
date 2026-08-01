#!/usr/bin/env python3
"""Reject Dart directives that appear after the first declaration."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE_PREFIXES = ("library ", "import ", "export ", "part ", "part of ")


def strip_comments(text: str) -> str:
    output: list[str] = []
    index = 0
    in_block = False
    while index < len(text):
        if in_block:
            end = text.find("*/", index)
            if end < 0:
                break
            index = end + 2
            in_block = False
            continue
        if text.startswith("/*", index):
            in_block = True
            index += 2
            continue
        end = text.find("\n", index)
        if end < 0:
            end = len(text)
        line = text[index:end]
        marker = line.find("//")
        if marker >= 0:
            line = line[:marker]
        output.append(line)
        index = end + 1
    return "\n".join(output)


def check(path: Path) -> list[str]:
    errors: list[str] = []
    seen_declaration = False
    directive_open = False
    for number, raw in enumerate(strip_comments(path.read_text(encoding="utf-8")).splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if directive_open:
            if ";" in line:
                directive_open = False
            continue
        is_directive = line.startswith(DIRECTIVE_PREFIXES)
        if is_directive:
            if seen_declaration:
                errors.append(f"{path.relative_to(ROOT)}:{number}: directive after declaration")
            directive_open = ";" not in line
            continue
        seen_declaration = True
    return errors


def main() -> None:
    errors = [error for path in ROOT.rglob("*.dart") for error in check(path)]
    if errors:
        raise SystemExit("\n".join(errors))
    print("Dart library directive order: OK")


if __name__ == "__main__":
    main()
