#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DartStructureError(RuntimeError):
    pass


def _strip_comments_and_strings(source: str) -> str:
    output: list[str] = []
    index = 0
    state: str | None = None
    quote = ''
    triple = False
    raw = False
    while index < len(source):
        char = source[index]
        if state == 'line-comment':
            if char == '\n':
                state = None
                output.append(char)
            else:
                output.append(' ')
            index += 1
            continue
        if state == 'block-comment':
            if source.startswith('*/', index):
                output.extend('  ')
                index += 2
                state = None
            else:
                output.append('\n' if char == '\n' else ' ')
                index += 1
            continue
        if state == 'string':
            if triple and source.startswith(quote * 3, index):
                output.extend('   ')
                index += 3
                state = None
            elif not triple and char == quote:
                output.append(' ')
                index += 1
                state = None
            elif not raw and char == '\\':
                output.extend('  ')
                index += 2
            else:
                output.append('\n' if char == '\n' else ' ')
                index += 1
            continue
        if source.startswith('//', index):
            output.extend('  ')
            index += 2
            state = 'line-comment'
            continue
        if source.startswith('/*', index):
            output.extend('  ')
            index += 2
            state = 'block-comment'
            continue
        raw = False
        if (
            char in {'r', 'R'}
            and index + 1 < len(source)
            and source[index + 1] in {'\'', '"'}
        ):
            output.append(' ')
            index += 1
            char = source[index]
            raw = True
        if char in {'\'', '"'}:
            quote = char
            triple = source.startswith(char * 3, index)
            state = 'string'
            width = 3 if triple else 1
            output.extend(' ' * width)
            index += width
            continue
        output.append(char)
        index += 1
    return ''.join(output)


def _line(source: str, offset: int) -> int:
    return source.count('\n', 0, offset) + 1


def _check_delimiters(path: Path, source: str) -> None:
    stack: list[tuple[str, int]] = []
    pairs = {')': '(', ']': '[', '}': '{'}
    for offset, char in enumerate(source):
        if char in '([{':
            stack.append((char, offset))
        elif char in ')]}':
            if not stack or stack[-1][0] != pairs[char]:
                raise DartStructureError(
                    f'{path.relative_to(ROOT)}:{_line(source, offset)} '
                    f'has mismatched {char}'
                )
            stack.pop()
    if stack:
        opening, offset = stack[-1]
        raise DartStructureError(
            f'{path.relative_to(ROOT)}:{_line(source, offset)} '
            f'has unclosed {opening}'
        )


def _parenthesis_ranges(source: str) -> list[tuple[int, int]]:
    stack: list[int] = []
    ranges: list[tuple[int, int]] = []
    for offset, char in enumerate(source):
        if char == '(':
            stack.append(offset)
        elif char == ')' and stack:
            ranges.append((stack.pop(), offset))
    return ranges


def _top_level_segments(body: str, *, track_angles: bool = True) -> list[str]:
    depth = 0
    start = 0
    segments: list[str] = []
    for offset, char in enumerate(body):
        openings = '([{<' if track_angles else '([{'
        closings = ')]}>' if track_angles else ')]}'
        if char in openings:
            depth += 1
        elif char in closings:
            depth = max(0, depth - 1)
        elif char == ',' and depth == 0:
            segments.append(body[start:offset])
            start = offset + 1
    segments.append(body[start:])
    return segments


def _top_level_split(body: str, delimiter: str) -> list[str]:
    depth = 0
    start = 0
    segments: list[str] = []
    for offset, char in enumerate(body):
        if char in '([{':
            depth += 1
        elif char in ')]}':
            depth = max(0, depth - 1)
        elif char == delimiter and depth == 0:
            segments.append(body[start:offset])
            start = offset + 1
    segments.append(body[start:])
    return segments


def _check_c_style_for_updates(path: Path, source: str) -> None:
    ranges = {start: end for start, end in _parenthesis_ranges(source)}
    for match in re.finditer(r'\bfor\s*\(', source):
        start = source.find('(', match.start(), match.end())
        end = ranges.get(start)
        if end is None:
            continue
        parts = _top_level_split(source[start + 1:end], ';')
        if len(parts) != 3:
            continue
        _, condition, update = (part.strip() for part in parts)
        if condition and not update:
            raise DartStructureError(
                f'{path.relative_to(ROOT)}:{_line(source, match.start())} has '
                'a conditional C-style for loop without an update clause'
            )


def _check_duplicate_named_arguments(path: Path, source: str) -> None:
    for start, end in _parenthesis_ranges(source):
        body = source[start + 1:end]
        labels: list[str] = []
        for segment in _top_level_segments(body, track_angles=False):
            match = re.match(r'\s*([A-Za-z_]\w*)\s*:', segment)
            if match is not None:
                labels.append(match.group(1))
        duplicates = sorted({label for label in labels if labels.count(label) > 1})
        if duplicates:
            raise DartStructureError(
                f'{path.relative_to(ROOT)}:{_line(source, start)} repeats '
                f'named argument(s): {", ".join(duplicates)}'
            )


def _check_duplicate_parameters(path: Path, source: str) -> None:
    modifiers = {'required', 'covariant', 'final', 'var', 'const', 'this', 'super'}
    for start, end in _parenthesis_ranges(source):
        after = source[end + 1:end + 40]
        if re.match(r'\s*(?:async\*?|sync\*?|\{|=>|:)', after) is None:
            continue
        before = source[max(0, start - 120):start]
        if re.search(r'[A-Za-z_]\w*(?:\s*<[^;{}()]*>)?\s*$', before) is None:
            continue
        segments = _top_level_segments(source[start + 1:end])
        if any(re.match(r'\s*[A-Za-z_]\w*\s*:', segment) for segment in segments):
            continue
        names: list[str] = []
        for segment in segments:
            cleaned = segment.strip().strip('{}[]').split('=', 1)[0].strip()
            if not cleaned:
                continue
            field = re.search(r'\b(?:this|super)\.([A-Za-z_]\w*)\s*$', cleaned)
            if field is not None:
                names.append(field.group(1))
                continue
            identifiers = [
                item
                for item in re.findall(r'[A-Za-z_]\w*', cleaned)
                if item not in modifiers
            ]
            if identifiers:
                names.append(identifiers[-1])
        duplicates = sorted({name for name in names if names.count(name) > 1})
        if duplicates:
            raise DartStructureError(
                f'{path.relative_to(ROOT)}:{_line(source, start)} repeats '
                f'parameter(s): {", ".join(duplicates)}'
            )


def _check_relative_imports(path: Path, original: str) -> None:
    for match in re.finditer(
        r"^\s*(?:import|export|part)\s+['\"]([^'\"]+)['\"]",
        original,
        flags=re.M,
    ):
        target = match.group(1)
        if ':' in target or target.startswith('/'):
            continue
        resolved = (path.parent / target).resolve()
        if not resolved.is_file():
            raise DartStructureError(
                f'{path.relative_to(ROOT)}:{_line(original, match.start())} '
                f'references missing file {target}'
            )


def check_repository(root: Path = ROOT) -> tuple[int, int]:
    files = sorted(root.rglob('*.dart'))
    tests = 0
    for path in files:
        original = path.read_text(encoding='utf-8')
        stripped = _strip_comments_and_strings(original)
        _check_delimiters(path, stripped)
        _check_duplicate_named_arguments(path, stripped)
        _check_c_style_for_updates(path, stripped)
        _check_duplicate_parameters(path, stripped)
        _check_relative_imports(path, original)
        if path.name.endswith('_test.dart'):
            tests += 1
            if re.search(r'\bvoid\s+main\s*\(', stripped) is None:
                raise DartStructureError(
                    f'{path.relative_to(root)} has no top-level test main()'
                )
    return len(files), tests


def main() -> None:
    try:
        files, tests = check_repository()
    except DartStructureError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        raise SystemExit(1) from error
    print(f'Dart structure: OK ({files} files, {tests} test files)')


if __name__ == '__main__':
    main()
