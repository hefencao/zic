#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(
            f"FAIL: {path} missing native worker exit ownership tokens: {missing}"
        )


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(
            f"FAIL: {path} contains rejected per-request exit race tokens: {found}"
        )


for path, signal in (
    (
        "packages/bridge/lib/src/native_decode_pool.dart",
        "_decodeWorkerExitedSignal",
    ),
    (
        "packages/bridge/lib/src/native_source_write_pool.dart",
        "_sourceWriteWorkerExitedSignal",
    ),
):
    require(
        path,
        "Completer<Object?>? _activeResponse;",
        "void attachExitHandler(",
        "void _handleWorkerExit(",
        "Future<void> _replenishWorkers() async",
        "worker.exited",
        "_activeRuns",
        f"active.complete({signal});",
    )
    forbid(
        path,
        "Future.any<Object?>(<Future<Object?>>[",
        f"_exited.then<Object?>((_) => {signal})",
    )

print("native worker exit listener/retirement ownership: OK")
