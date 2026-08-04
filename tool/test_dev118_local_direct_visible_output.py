from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    for needle in needles:
        assert needle in text, f"{path} missing {needle!r}"


require(
    "packages/local_media_ui/lib/src/local_media_screens.dart",
    "disposition: ByteResponseDisposition.durableImmutable",
)
require(
    "packages/transport/lib/src/io_transport.dart",
    "final class FileTransport",
    "disposition: ByteResponseDisposition.durableImmutable",
)
require(
    "packages/pipeline_runtime/lib/src/asset_bundle_transport.dart",
    "disposition: ByteResponseDisposition.durableImmutable",
)
require(
    "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
    "localSourceConcurrency: 2",
    "remoteSourceConcurrency: 5",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_transfer_progress.dart",
    "scheme == 'file' || scheme == 'content' || scheme == 'asset'",
)
require(
    "packages/sessions/lib/src/download_job.dart",
    "response.disposition == ByteResponseDisposition.durableImmutable",
    "session.recordResume(restarted: true)",
    "residentSource: _residentSourceFor",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
    "_readDirectImmutableSource",
    "source: 'direct-source'",
    "readMode: 'direct-read-all'",
)
require(
    "packages/domain/lib/src/reader_observation.dart",
    "final List<Coverage> visibleCoverages",
)
require(
    "packages/reader/lib/src/reader_view.dart",
    "geometry.visibleCoverages",
    "visibleCoveragesOverride: visibleCoverages",
)
require(
    "packages/pipeline/lib/src/role_window.dart",
    "visible,",
    "PageRole.visible => 92",
)
require(
    "packages/pipeline/lib/src/heuristic_policy.dart",
    "role == PageRole.visible",
    "PageRole.visible => 880",
    "_estimatedStaticOutputBytes",
)
require(
    "packages/sessions/lib/src/frame_budget.dart",
    "role == PageRole.visible",
)

heuristic = (ROOT / "packages/pipeline/lib/src/heuristic_policy.dart").read_text(
    encoding="utf-8"
)
assert "staticOutputBudgetBytes ~/" not in heuristic
assert "PageRole.visible => 0" in heuristic, (
    "animated extra-visible pages must not receive speculative multi-frame decode"
)

print("dev118 local direct ingress and visible output contract: OK")

require(
    "packages/sessions/lib/src/download_session.dart",
    "'residentSource': _residentSource",
)
require(
    "tool/analyze_frame_pipeline_trace.py",
    '"residentSourceCounts"',
)
