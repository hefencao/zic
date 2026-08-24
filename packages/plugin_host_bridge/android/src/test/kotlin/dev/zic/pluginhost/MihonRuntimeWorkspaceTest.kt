package dev.zic.pluginhost

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class MihonRuntimeWorkspaceTest {
    @Test
    fun runtimeWorkspaceIsolatedButImmutableArtifactsAreReusable() {
        val codeCache = Files.createTempDirectory("zic-mihon-workspace-").toFile()
        try {
            val first = mihonRuntimeRoot(codeCache, "plugin/id", "1.6 alpha", "driver:a")
            val second = mihonRuntimeRoot(codeCache, "plugin/id", "1.6 alpha", "driver:b")
            val artifact = mihonRuntimeArtifactsRoot(
                codeCache,
                "plugin/id",
                "1.6 alpha",
                "payload-sha",
                "1.6",
                "arm64-v8a",
            )

            assertNotEquals(first.path, second.path)
            assertEquals(
                artifact.path,
                mihonRuntimeArtifactsRoot(
                    codeCache,
                    "plugin/id",
                    "1.6 alpha",
                    "payload-sha",
                    "1.6",
                    "arm64-v8a",
                ).path,
            )
            assertTrue(first.canonicalPath.startsWith(File(codeCache, "mihon").canonicalPath))
            assertTrue(second.canonicalPath.startsWith(File(codeCache, "mihon").canonicalPath))
            assertTrue(artifact.canonicalPath.startsWith(File(codeCache, "mihon").canonicalPath))
            assertFalse(first.path.contains("plugin/id"))
            assertFalse(first.path.contains("1.6 alpha"))
            assertFalse(first.path.contains("driver:a"))

            first.mkdirs()
            File(first, "extension.apk").writeText("fixture")
            artifact.mkdirs()
            File(artifact, "extension.apk").writeText("cached fixture")
            val legacy = File(codeCache, "mihon/legacy-root").apply { mkdirs() }
            cleanupStaleMihonRuntimeRoots(codeCache)
            assertTrue(first.exists())
            assertTrue(artifact.exists())
            assertFalse(legacy.exists())
        } finally {
            codeCache.deleteRecursively()
        }
    }
}
