#!/usr/bin/env python3
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "apps/app/android/app/src/main/kotlin/dev/zic/zic/MainActivity.kt"
text = MAIN.read_text(encoding="utf-8")

required = (
    'Thread(runnable, "zic-saf-path")',
    'Executors.newFixedThreadPool(4)',
    'Thread(runnable, "zic-local-read-open-$index")',
    '"safPrewarmRecentRead",',
    'private fun safPrewarmRecentRead(call: MethodCall): Boolean',
    'java.util.concurrent.locks.ReentrantReadWriteLock()',
    '"presentationOpenDirect",',
    '"presentationOpenSaf" -> localReadOpenExecutor',
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
    'localReadOpenExecutor.shutdownNow()',
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
    "safPrewarmRecentRead",
    "presentationOpenDirect",
    "presentationOpenSaf",
):
    if f'"{method}"' not in routing:
        raise SystemExit(f"read-only open escaped read-open executor: {method}")
for method in (
    "safDelete",
    "safRename",
    "safExists",
    "safList",
):
    if f'"{method}"' in routing:
        raise SystemExit(f"path operation incorrectly routed as descriptor I/O: {method}")

if '"safReplace"' in text or 'private fun safReplace(' in text:
    raise SystemExit('hidden SAF overwrite bridge must remain deleted')

print("Android SAF path/striped-descriptor executor boundary: OK")

# Execute the production existence method against a provider that counts exact
# document queries and directory resolutions. A cached locator is not proof;
# stale/absent hints must still recover, and access failures must stay failures.
start = text.index('private fun safExists(')
brace = text.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
exists_method = text[start:end]
start = text.index('private fun persistDirectoryReadGrant(')
brace = text.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
grant_method = text[start:end]
picker_result = text[text.index('override fun onActivityResult('):text.index('if (requestCode != TRACE_EXPORT_REQUEST)')]
assert 'persistDirectoryReadGrant(uri, data?.flags ?: 0)' in picker_result
assert 'pending.error("download-pick-permission-failed"' in picker_result
assert 'null)\n                return\n            }\n            pending.success' in picker_result
fixture = r'''
data class Uri(val value: String) {
    companion object { fun parse(value: String) = Uri(value) }
}
object Intent {
    const val FLAG_GRANT_READ_URI_PERMISSION = 1
    const val FLAG_GRANT_WRITE_URI_PERMISSION = 2
}
data class Grant(val uri: Uri, val isReadPermission: Boolean)
object DocumentsContract {
    object Document { const val COLUMN_DOCUMENT_ID = "document_id" }
    fun buildDocumentUriUsingTree(tree: Uri, id: String) = Uri(tree.value + "/" + id)
}
class MethodCall(private val values: Map<String, Any?>) {
    @Suppress("UNCHECKED_CAST")
    fun <T> argument(key: String): T? = values[key] as T?
}
class Cursor(private val present: Boolean) : AutoCloseable {
    var closed = false
    fun moveToFirst() = present
    override fun close() { closed = true }
}
class Resolver {
    var persistedUriPermissions = listOf<Grant>()
    var persistCalls = 0
    var persistFlags = 0
    var savesGrant = true
    fun takePersistableUriPermission(uri: Uri, flags: Int) {
        persistCalls++; persistFlags = flags
        failure?.let { throw it }
        if (savesGrant) persistedUriPermissions = listOf(Grant(uri, flags and 1 != 0))
    }
    var queries = 0
    var cursor: Cursor? = Cursor(true)
    var failure: Exception? = null
    fun query(uri: Uri, projection: Array<String>, selection: String?,
        arguments: Array<String>?, order: String?): Cursor? {
        check(uri.value == "tree/known")
        check(projection.contentEquals(arrayOf("document_id")))
        check(selection == null && arguments == null && order == null)
        queries++
        failure?.let { throw it }
        return cursor
    }
}
class Host {
    val contentResolver = Resolver()
    var cached: String? = "known"
    var resolved: Uri? = Uri("tree/replacement")
    var resolves = 0
    var forgotten = 0
    var invalidated = 0
    var root = true
    fun persist(flags: Int) = persistDirectoryReadGrant(Uri("tree"), flags)
    fun exists(path: String = "comic/page.webp") = safExists(MethodCall(
        mapOf("treeUri" to "tree", "relativePath" to path)))
    private fun isSafeRelativePath(path: String, allowRoot: Boolean) =
        (path.isNotEmpty() || allowRoot) && ".." !in path.split('/')
    private fun safTreeRoot(tree: String): Any? = if (root) tree else null
    private fun cachedSafExactDocumentId(tree: String, path: String): String? {
        check(tree == "tree" && path == "comic/page.webp")
        return cached
    }
    private fun forgetSafExactLocator(tree: String, path: String) {
        check(tree == "tree" && path == "comic/page.webp")
        cached = null; forgotten++
    }
    private fun invalidateSafReadParentListing(tree: String, path: String) {
        check(tree == "tree" && path == "comic/page.webp")
        invalidated++
    }
    private fun resolveReadUri(tree: String, path: String): Uri? {
        check(tree == "tree" && path == "comic/page.webp")
        resolves++
        return resolved
    }
__EXISTS_METHOD__
__GRANT_METHOD__
}
fun main() {
    for (flags in listOf(1, 3, 67)) {
        val granted = Host()
        granted.persist(flags)
        check(granted.contentResolver.persistCalls == 1)
        check(granted.contentResolver.persistFlags == flags and 3)
    }
    for (flags in listOf(0, 2)) {
        val missingGrant = Host()
        check(runCatching { missingGrant.persist(flags) }.exceptionOrNull() is SecurityException)
        check(missingGrant.contentResolver.persistCalls == 0)
    }
    val notSaved = Host().apply { contentResolver.savesGrant = false }
    check(runCatching { notSaved.persist(3) }.exceptionOrNull() is SecurityException)
    val rejected = Host().apply { contentResolver.failure = SecurityException() }
    check(runCatching { rejected.persist(3) }.exceptionOrNull() is SecurityException)
    val hit = Host()
    check(hit.exists())
    check(hit.contentResolver.queries == 1 && hit.resolves == 0)
    check(hit.contentResolver.cursor!!.closed)
    for (mode in 0..2) {
        val stale = Host()
        when (mode) {
            0 -> stale.contentResolver.cursor = Cursor(false)
            1 -> stale.contentResolver.cursor = null
            2 -> stale.contentResolver.failure = java.io.FileNotFoundException()
        }
        check(stale.exists())
        check(stale.forgotten == 1 && stale.invalidated == 1 && stale.resolves == 1)
        if (mode == 0) check(stale.contentResolver.cursor!!.closed)
    }
    val missing = Host().apply {
        contentResolver.cursor = Cursor(false); resolved = null
    }
    check(!missing.exists() && missing.resolves == 1)
    val legacy = Host().apply { cached = null }
    check(legacy.exists())
    check(legacy.contentResolver.queries == 0 && legacy.resolves == 1)
    val denied = Host().apply { contentResolver.failure = SecurityException() }
    check(runCatching { denied.exists() }.exceptionOrNull() is SecurityException)
    check(denied.forgotten == 0 && denied.resolves == 0)
    val unsafe = Host()
    check(!unsafe.exists("../page.webp") && unsafe.contentResolver.queries == 0)
    check(unsafe.exists("") && unsafe.contentResolver.queries == 0)
    unsafe.root = false
    check(!unsafe.exists(""))
    println("SAF exact existence: provider proof, scoped recovery and access failures OK")
}
'''.replace('__EXISTS_METHOD__', exists_method).replace('__GRANT_METHOD__', grant_method)
kotlinc = shutil.which('kotlinc')
java = shutil.which('java')
if not kotlinc or not java:
    print('SKIP: kotlinc/java unavailable for SAF exact-existence behavior')
else:
    with tempfile.TemporaryDirectory(prefix='zic-saf-existence-') as directory:
        source = Path(directory) / 'SafExistence.kt'
        jar = Path(directory) / 'saf-existence.jar'
        source.write_text(fixture, encoding='utf-8')
        subprocess.run([kotlinc, str(source), '-include-runtime', '-d', str(jar)], check=True)
        subprocess.run([java, '-jar', str(jar)], check=True)
