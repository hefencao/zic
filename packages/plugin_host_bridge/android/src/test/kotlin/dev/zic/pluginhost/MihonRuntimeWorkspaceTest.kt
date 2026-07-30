package dev.zic.pluginhost

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class MihonRuntimeWorkspaceTest {
    @Test
    fun runtimeWorkspaceIsUniquePerDriverAndContainedInCodeCache() {
        val codeCache = Files.createTempDirectory("zic-mihon-workspace-").toFile()
        try {
            val first = mihonRuntimeRoot(codeCache, "plugin/id", "1.6 alpha", "driver:a")
            val second = mihonRuntimeRoot(codeCache, "plugin/id", "1.6 alpha", "driver:b")

            assertNotEquals(first.path, second.path)
            assertTrue(first.canonicalPath.startsWith(File(codeCache, "mihon").canonicalPath))
            assertTrue(second.canonicalPath.startsWith(File(codeCache, "mihon").canonicalPath))
            assertFalse(first.path.contains("plugin/id"))
            assertFalse(first.path.contains("1.6 alpha"))
            assertFalse(first.path.contains("driver:a"))

            first.mkdirs()
            File(first, "extension.apk").writeText("fixture")
            cleanupStaleMihonRuntimeRoots(codeCache)
            assertFalse(File(codeCache, "mihon").exists())
        } finally {
            codeCache.deleteRecursively()
        }
    }
}
