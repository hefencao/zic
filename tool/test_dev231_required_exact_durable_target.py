#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def need(path, token, label):
    text=(ROOT/path).read_text()
    if token not in text:
        raise SystemExit(f"missing {label}: {path}: {token}")

def forbid(path, token, label):
    text=(ROOT/path).read_text()
    if token in text:
        raise SystemExit(f"forbidden {label}: {path}: {token}")

need(Path('packages/sessions/lib/src/download_transfer_owner.dart'),'requiredExactDurableTargets','required exact targets owner API')
need(Path('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart'),'requiredExactTargets','handoff target resolver')
need(Path('packages/downloads/lib/src/promoted_artifact_cache_handoff.dart'),"'stored-required-exact-alias'",'required alias trace')
need(Path('packages/downloads/lib/src/composition_download_transfer_runtime.dart'),'handoff.persist(session, exactId: id)','direct exact durable barrier')
forbid(Path('packages/downloads/lib/src/composition_download_transfer_runtime.dart'),'physical transfer artifact is unavailable for exact materialization','old physical-durable copy bridge')
need(Path('packages/downloads/test/chapter_downloads_test.dart'),'openArtifactStream(oldId), isNull','no physical anchor durable duplicate')
need(Path('packages/downloads/test/chapter_downloads_test.dart'),"event.payload['action'] == 'stored-required-exact-alias'",'behavior trace assertion')
need(Path('docs/adr/0211-required-exact-durable-target.md'),'状态：Accepted','ADR')
print('dev.231 required exact durable target: OK')
