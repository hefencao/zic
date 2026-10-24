#!/usr/bin/env python3
"""Conditional expression calls are not constructor parameter declarations."""
from pathlib import Path
from check_dart_structure import (
    ROOT, DartStructureError, _check_delimiters, _check_duplicate_parameters,
    _strip_comments_and_strings,
)


def main() -> None:
    path = ROOT / 'structure_fixture.dart'
    _check_duplicate_parameters(path, _strip_comments_and_strings('''
class Point { final double width = 1; }
double min(double a, double b) => a < b ? a : b;
double compare(Point a, Point b, bool vertical) => vertical
    ? min(a.width, b.width) : min(a.width, b.width);
'''))
    for source in [
        'void duplicate(int width, int width) {}',
        'class Widget { Widget(int width, int width) : assert(width > 0); }',
    ]:
        try:
            _check_duplicate_parameters(path, source)
        except DartStructureError:
            continue
        raise AssertionError('real duplicate parameter was not rejected')
    # A raw backslash must not escape its closing quote or hide real braces.
    raw_source = "const slash = r'" + "\\" + "';\nvoid valid() { print(slash); }"
    _check_delimiters(path, _strip_comments_and_strings(raw_source))
    try:
        _check_delimiters(path, _strip_comments_and_strings(raw_source + '{'))
    except DartStructureError:
        pass
    else:
        raise AssertionError('raw string hid an unclosed delimiter')
    print('Dart structure conditional/constructor distinction: OK')


if __name__ == '__main__':
    main()
