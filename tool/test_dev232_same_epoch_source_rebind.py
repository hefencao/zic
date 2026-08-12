#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def need(path, token, label):
    text=(ROOT/path).read_text()
    if token not in text:
        raise SystemExit(f"missing {label}: {path}: {token}")

need(Path('packages/sessions/lib/src/decode_session.dart'),'EncodedSource? _boundSource;','decode source binding identity')
need(Path('packages/sessions/lib/src/decode_session.dart'),'identical(_boundSource, source)','same-epoch source identity check')
need(Path('packages/sessions/lib/src/decode_session.dart'),'_boundSource = source;','source binding update')
need(Path('packages/sessions/lib/src/decode_session.dart'),'_boundSource = null;','source binding release')
need(Path('packages/sessions/test/decode_session_test.dart'),'rebinds when ingress replaces encoded source inside the same epoch','behavior regression')
need(Path('docs/adr/0212-same-epoch-encoded-source-rebind.md'),'状态：Accepted','ADR')
print('dev.232 same-epoch source rebind: OK')
