#!/usr/bin/env python3
"""Keep raw technical failures traceable or directly copyable in user UI."""
from pathlib import Path
import re

ROOTS = (
    Path('apps/app/lib'),
    Path('packages/local_media_ui/lib'),
    Path('packages/reader_runtime/lib'),
    Path('packages/reader/lib'),
)

# A raw interpolated exception in a plain SnackBar forces users to transcribe
# diagnostics. Route it through the copyable helper (or a feature-specific
# trace/copy surface) instead.
FORBIDDEN = re.compile(
    r"SnackBar\s*\(\s*content\s*:\s*Text\([^\n]*(?:\$error|\$failure|error\.toString\(\)|failure\.toString\(\))"
)

violations: list[str] = []
for root in ROOTS:
    for path in root.rglob('*.dart'):
        text = path.read_text(encoding='utf-8')
        for match in FORBIDDEN.finditer(text):
            line = text.count('\n', 0, match.start()) + 1
            violations.append(f'{path}:{line}')

if violations:
    raise SystemExit(
        'raw user-visible technical error is neither copy-helper nor dedicated diagnostic surface: '
        + ', '.join(violations)
    )

# Explicit regression anchors for the two shared presentation boundaries.
app_helper = Path('apps/app/lib/diagnostic_error_ui.dart').read_text(encoding='utf-8')
reader = Path('packages/reader_runtime/lib/src/reader_runtime_screen.dart').read_text(encoding='utf-8')
for token in ('copyDiagnosticText', "label: '复制'", 'ClipboardData(text: message)'):
    assert token in app_helper
for token in ('_copyableReaderErrorSnackBar', "label: '复制'", 'ClipboardData(text: message)'):
    assert token in reader

print('user-visible diagnostic error copy/trace contract: OK')
