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
    "session.recordResume(",
    "restarted: true",
    "bodyAuthority: response.bodyAuthority",
)
require(
    "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
    "_readDirectImmutableSource",
    "source: 'direct-source'",
    "readMode: 'direct-read-all'",
)
require(
    "packages/pipeline/lib/src/heuristic_policy.dart",
    "runtimeLocalStaticPages.contains(entry.key)",
    "retainOutput: visibleStatic || localStaticReady",
    "targetWatermark: decodeWatermark",
)

heuristic = (ROOT / "packages/pipeline/lib/src/heuristic_policy.dart").read_text(
    encoding="utf-8"
)
assert "staticOutputBudgetBytes" not in heuristic
assert "_estimatedStaticOutputBytes" not in heuristic
print("dev118 local direct ingress contract: OK")

require(
    "packages/sessions/lib/src/download_session.dart",
    "'residentSource': residentSource",
)
require(
    "tool/analyze_frame_pipeline_trace.py",
    '"residentSourceCounts"',
)
