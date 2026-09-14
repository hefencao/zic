#!/usr/bin/env python3
"""Guard dev.291 physical-ingress source metadata authority and diagnostics."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def text(path): return (ROOT / path).read_text(encoding="utf-8")
def req(ok, msg):
    if not ok: raise SystemExit(f"FAIL: {msg}")
def require(path, *markers):
    body = text(path)
    missing = [marker for marker in markers if marker not in body]
    req(not missing, f"{path} missing dev.291 contract: {missing}")

pub = text("apps/app/pubspec.yaml")
m = re.search(r"^version:\s+0\.31\.0\+(\d+)\s*$", pub, re.M)
req(m is not None and int(m.group(1)) >= 291, "dev.291 app version missing")
version = int(m.group(1))

require(
    "packages/sessions/lib/src/download_session.dart",
    "const int _sourceMetadataPrefixLength = 64;",
    "final int? sourceCanvasWidth;",
    "final int? sourceCanvasHeight;",
    "Uint8List readIngressPrefix(int maxBytes)",
    "Uint8List readSourceMetadataPrefix()",
    "void _appendSourceMetadataPrefix(int offset, Uint8List chunk)",
    "final info = parseWebpPrefixInfo(Uint8List.fromList(_prefix));",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_page_stream.dart",
    "Uint8List readMetadataPrefix()",
    "session.readSourceMetadataPrefix()",
    "int get metadataPrefixLength",
)
stream = text("packages/pipeline_runtime/lib/src/pipeline_page_stream.dart")
req("session.artifact.readPrefix" not in stream,
    "PipelinePageStream must not read source metadata from resident session Artifact")
req("session.readSourcePrefix(" not in stream,
    "Pipeline presentation metadata must not expand into encoded body replay")
req("residentReplaySource" not in stream,
    "PipelinePageStream metadata projection must not own resident body replay")
reader = text("packages/pipeline_runtime/lib/src/pipeline_reader_session.dart")
req("download.artifact.readPrefix" not in reader,
    "Pipeline dimension resolution must not guess Artifact ownership")
for marker in (
    "snapshot?.sourceCanvasWidth",
    "snapshot?.sourceCanvasHeight",
    "source = 'physical-ingress-source-canvas';",
):
    req(marker in reader, f"Pipeline physical metadata projection missing: {marker}")
require(
    "packages/sessions/test/download_session_test.dart",
    "resident cache retains source metadata prefix outside Artifact",
    "expect(session.artifact.committedLength, 0);",
    "expect(session.snapshot.sourceCanvasWidth, 640);",
    "expect(session.snapshot.sourceCanvasHeight, 1200);",
    "expect(session.readIngressPrefix(prefix.length), prefix);",
    "source metadata prefix stays in-memory while receiving body grows",
    "expect(session.sourceMetadataPrefixLength, 64);",
    "resident source prefix uses external body authority beyond metadata",
    "final prefix = await session.readSourcePrefix(96,",
    "residentReplayChunks: (endExclusive) async",
)
req((ROOT / "docs/adr/0270-physical-ingress-source-metadata-authority.md").is_file(),
    "missing dev.291 governance file: docs/adr/0270-physical-ingress-source-metadata-authority.md")
require(
    "docs/audits/dev291-source-metadata-owner-and-scale-audit.md",
    "dev.291",
    "sourceCanvas",
    "layout",
)
require("docs/ARCHITECTURE.md", "generation-local source-metadata prefix", "sourceCanvasWidth")
require("docs/SPEC.md", "generation-local source-metadata prefix", "physical-ingress-source-canvas")
require("docs/IMPLEMENTATION_STATUS.md", "residentBodyBacked", "metadataPrefix", "source metadata")
require("CHANGELOG.md", "0.31.0-dev.291", "Physical ingress source metadata authority")
req("test_dev291_physical_source_metadata_authority.py" in text("tool/check.sh"),
    "dev.291 gate not wired into tool/check.sh")
print("PASS: dev.291 physical ingress source metadata authority")
