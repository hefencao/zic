#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"FAIL: {path} missing dev.100 tokens: {missing}")


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f"FAIL: {path} contains rejected dev.100 tokens: {found}")


import re
version = re.search(r"^version:\s*0\.31\.0\+(\d+)\s*$", read("apps/app/pubspec.yaml"), re.M)
if version is None or int(version.group(1)) < 100:
    raise SystemExit("FAIL: App build must be at least dev.100")
require(
    "packages/pipeline/lib/src/raster_plan.dart",
    "bool get prefersNearestNeighbor =>",
    "math.max(sourceWidth, sourceHeight) <= 64",
)
forbid("packages/pipeline/lib/src/raster_plan.dart", "isRenderUpscaled", "renderScale")
require(
    "apps/app/test/misc_settings_test.dart",
    "package:flutter/scheduler.dart",
    "SchedulerBinding.instance.schedulerPhase",
)
require(
    "apps/app/test/library_ui_test.dart",
    "details.localComicDetailsScreenKey",
)
forbid(
    "apps/app/test/reader_controls_test.dart",
    "adaptive reader classifier respects animation and page geometry",
)
require(
    "apps/app/test/source_browser_test.dart",
    "ZIC-QUARANTINE(Q-001): whole-App legacy runtime route",
    "ZIC-QUARANTINE(Q-002): persisted legacy route test timing",
    "ZIC-QUARANTINE(Q-003): whole-App retry test bootstrap race",
    "unawaited(refresh.show());",
    "expect(source.loadedResources, isEmpty);",
)
require(
    "packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart",
    "Future<void>? _prewarmFuture;",
    "_texturePresenter!.prewarm()",
)
require(
    "packages/texture_bridge/lib/src/android_texture_presenter.dart",
    "final lease = await create(width: 1, height: 1);",
    "await lease.release();",
)
require(
    "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture/TextureBridgePlugin.kt",
    "const val BLIT_LANE_COUNT = 1",
    "mainHandler.post {",
    "resultDispatchMicros\" to 0L",
    "result.success(",
)
require(
    "apps/app/lib/debug_trace.dart",
    "'decodedLeadMicros'",
    "'uploadBackpressureMicros'",
)
require(
    "packages/sessions/lib/src/playback_timer.dart",
    "int? get deadlineUs",
)
require(
    "packages/sessions/lib/src/upload_session.dart",
    "decodedLeadMicros",
    "uploadBackpressureMicros",
    "'decodedRole': decoded?.role.name ?? 'unknown'",
    "'uploadBackpressure': timing?.uploadBackpressureMicros ?? 0",
    'platform.platformUploadMicros -',
    'platform.platformRetainMicros -',
    'platform.platformBlitMicros -',
)
require(
    "tool/analyze_frame_pipeline_trace.py",
    "recordedDominantStageCounts",
    "normalized dominant stages",
    "decodedLeadMicros",
    "uploadBackpressureMicros",
)
require(
    "docs/testing/TEST_QUARANTINE.md",
    "默认测试套件不得使用匿名",
    "ZIC-QUARANTINE(Q-001):",
)
require("tool/check.sh", "check_test_quarantine.py")
require("tool/check.sh", "test_dev100_test_quarantine_texture_dispatch.py")
require("tool/check.sh", "test_texture_bridge_kotlin_compile.py")
require(
    "docs/adr/0084-test-quarantine-and-texture-schedule-reply.md",
    "0.31.0-dev.100",
)
require(
    "docs/audits/dev100-test-quarantine-playback-audit.md",
    "被否决方案清单",
)
require(
    "docs/audits/dev100-validation-results.md",
    "0.31.0-dev.100",
)
require(
    "docs/testing/TEST_QUARANTINE.md",
    "ZIC-QUARANTINE(Q-001):",
)

print("dev.100 test quarantine and texture reply ownership: OK")
