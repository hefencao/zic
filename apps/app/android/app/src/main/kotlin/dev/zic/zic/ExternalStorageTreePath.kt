package dev.zic.zic

import java.io.File

internal data class ExternalStorageVolumeRoot(
    val uuid: String?,
    val directory: File?,
)

/// Resolves an ExternalStorageProvider tree document id against Android's
/// current mounted-volume inventory. The returned path is only a Direct-access
/// candidate; callers must still prove SAF/Direct aliasing before persisting it.
internal fun resolveExternalStorageTreeDirectPath(
    documentId: String,
    primaryRoot: File,
    volumes: List<ExternalStorageVolumeRoot>,
): String? {
    val separator = documentId.indexOf(':')
    if (separator <= 0) return null
    val volumeId = documentId.substring(0, separator).trim()
    if (volumeId.isEmpty()) return null
    val relative = documentId.substring(separator + 1)
    val segments = relative.split('/').filter { it.isNotEmpty() }
    if (segments.any { it == "." || it == ".." }) return null

    val root = if (volumeId.equals("primary", ignoreCase = true)) {
        primaryRoot
    } else {
        val matching = volumes.filter { volume ->
            volume.uuid?.equals(volumeId, ignoreCase = true) == true &&
                volume.directory != null
        }
        if (matching.size != 1) return null
        matching.single().directory!!
    }

    return runCatching {
        val canonicalRoot = root.canonicalFile
        val candidate = segments.fold(canonicalRoot) { current, segment ->
            File(current, segment)
        }.canonicalFile
        val rootPrefix = canonicalRoot.path + File.separator
        if (candidate != canonicalRoot && !candidate.path.startsWith(rootPrefix)) {
            null
        } else if (!candidate.isDirectory) {
            null
        } else {
            candidate.absolutePath
        }
    }.getOrNull()
}
