package dev.zic.zic

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExternalStorageTreePathTest {
    @Test
    fun resolvesPrimaryAndUuidVolumesWithoutGuessingMountPaths() {
        withRoots { primary, firstMount, secondMount ->
            val primaryTarget = File(primary, "Manga/Series").also { it.mkdirs() }
            val removableTarget = File(firstMount, "Books/Series").also { it.mkdirs() }

            assertEquals(
                primaryTarget.canonicalPath,
                resolveExternalStorageTreeDirectPath(
                    "primary:Manga/Series",
                    primary,
                    listOf(ExternalStorageVolumeRoot("ABCD-1234", firstMount)),
                ),
            )
            assertEquals(
                removableTarget.canonicalPath,
                resolveExternalStorageTreeDirectPath(
                    "abcd-1234:Books/Series",
                    primary,
                    listOf(ExternalStorageVolumeRoot("ABCD-1234", firstMount)),
                ),
            )
        }
    }

    @Test
    fun sameUuidFollowsCurrentMountedDirectory() {
        withRoots { primary, firstMount, secondMount ->
            val firstTarget = File(firstMount, "Manga").also { it.mkdirs() }
            val secondTarget = File(secondMount, "Manga").also { it.mkdirs() }
            val documentId = "CAFE-BEEF:Manga"

            assertEquals(
                firstTarget.canonicalPath,
                resolveExternalStorageTreeDirectPath(
                    documentId,
                    primary,
                    listOf(ExternalStorageVolumeRoot("CAFE-BEEF", firstMount)),
                ),
            )
            assertEquals(
                secondTarget.canonicalPath,
                resolveExternalStorageTreeDirectPath(
                    documentId,
                    primary,
                    listOf(ExternalStorageVolumeRoot("CAFE-BEEF", secondMount)),
                ),
            )
        }
    }

    @Test
    fun rejectsUnknownAmbiguousAndEscapingVolumeMappings() {
        withRoots { primary, firstMount, secondMount ->
            File(firstMount, "Manga").mkdirs()
            File(secondMount, "Manga").mkdirs()

            assertNull(
                resolveExternalStorageTreeDirectPath(
                    "DEAD-BEEF:Manga",
                    primary,
                    listOf(ExternalStorageVolumeRoot("CAFE-BEEF", firstMount)),
                ),
            )
            assertNull(
                resolveExternalStorageTreeDirectPath(
                    "CAFE-BEEF:Manga",
                    primary,
                    listOf(
                        ExternalStorageVolumeRoot("CAFE-BEEF", firstMount),
                        ExternalStorageVolumeRoot("cafe-beef", secondMount),
                    ),
                ),
            )
            assertNull(
                resolveExternalStorageTreeDirectPath(
                    "CAFE-BEEF:../Manga",
                    primary,
                    listOf(ExternalStorageVolumeRoot("CAFE-BEEF", firstMount)),
                ),
            )
        }
    }

    private fun withRoots(
        operation: (primary: File, firstMount: File, secondMount: File) -> Unit,
    ) {
        val root = Files.createTempDirectory("zic-storage-volume-test").toFile()
        try {
            val primary = File(root, "primary").also { it.mkdirs() }
            val firstMount = File(root, "mount-a").also { it.mkdirs() }
            val secondMount = File(root, "mount-b").also { it.mkdirs() }
            operation(primary, firstMount, secondMount)
        } finally {
            root.deleteRecursively()
        }
    }
}
