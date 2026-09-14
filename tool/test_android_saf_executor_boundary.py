#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt"
text = MAIN.read_text(encoding="utf-8")

required = (
    'Thread(runnable, "zic-saf-path")',
    'Executors.newFixedThreadPool(4)',
    'Thread(runnable, "zic-saf-read-open-$index")',
    '"safPrewarmRecentRead" -> safReadOpenExecutor',
    'private fun safPrewarmRecentRead(call: MethodCall): Boolean',
    'java.util.concurrent.locks.ReentrantReadWriteLock()',
    '"presentationOpenSaf" -> safReadOpenExecutor',
    'List(4) { index ->',
    'Thread(runnable, "zic-saf-descriptor-$index")',
    'safDescriptorExecutors[Math.floorMod(handle, safDescriptorExecutors.size)]',
    'java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()',
    'private val safExactDocumentIdsLock = Any()',
    'private fun normalizeLegacySafExactLocatorKey(key: String): String',
    'treeUri.startsWith("/content://")',
    'repairedLegacyTreeKey',
    'safChildDocumentIds.computeIfAbsent(key)',
    '"safReadAt",',
    '"safLength",',
    '"presentationClose" -> safDescriptorExecutorFor(call)',
    'else -> safExecutor',
    'safExecutor.shutdownNow()',
    'safReadOpenExecutor.shutdownNow()',
    'safDescriptorExecutors.forEach { it.shutdownNow() }',
    'safDescriptors.clear()',
    'val statSize = pfd.statSize',
    'android.system.Os.fstat(pfd.fileDescriptor).st_size',
)
for token in required:
    if token not in text:
        raise SystemExit(f"missing SAF executor boundary token: {token}")

routing_start = text.index("val executor = when (call.method)")
routing_end = text.index("executor.execute", routing_start)
routing = text[routing_start:routing_end]
for method in (
    "safRead",
    "safReadAt",
    "safWrite",
    "safSeek",
    "safLength",
    "safClose",
    "presentationClose",
):
    if f'"{method}"' not in routing:
        raise SystemExit(f"descriptor operation escaped descriptor executor: {method}")
for method in (
    "presentationOpenDirect",
    "safDelete",
    "safRename",
    "safReplace",
    "safExists",
    "safList",
):
    if f'"{method}"' in routing:
        raise SystemExit(f"path operation incorrectly routed as descriptor I/O: {method}")

print("Android SAF path/striped-descriptor executor boundary: OK")
