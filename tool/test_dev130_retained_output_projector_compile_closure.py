#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ROOTS = [
    ROOT / "apps",
    ROOT / "packages",
    ROOT / "native",
]
FORBIDDEN = "_RetainedAndroidTextureOutputFrame"

hits: list[str] = []
for base in PRODUCTION_ROOTS:
    if not base.exists():
        continue
    for path in base.rglob("*"):
        if not path.is_file() or path.suffix not in {".dart", ".kt", ".java", ".rs", ".h", ".cc", ".cpp"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if FORBIDDEN in text:
            hits.append(str(path.relative_to(ROOT)))

if hits:
    raise SystemExit(
        "dev.130 compile closure failed; deleted retained output type remains in production: "
        + ", ".join(sorted(hits))
    )

runtime = (
    ROOT
    / "packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart"
).read_text(encoding="utf-8")
required = [
    "if (frame is! _AndroidTextureOutputFrame)",
    "Android output projector requires an Android texture frame",
]
missing = [item for item in required if item not in runtime]
if missing:
    raise SystemExit(
        "dev.130 Android projector contract missing: " + ", ".join(missing)
    )

print("dev.130 retained output projector compile closure: OK")
