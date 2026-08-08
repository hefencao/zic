package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import rx.Observable

interface CatalogueSource : Source {
    override val lang: String

    override suspend fun getPopularManga(page: Int): MangasPage =
        fetchPopularManga(page).awaitSingleCompat()

    override suspend fun getLatestUpdates(page: Int): MangasPage =
        fetchLatestUpdates(page).awaitSingleCompat()

    override suspend fun getSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): MangasPage = fetchSearchManga(page, query, filters).awaitSingleCompat()

    override suspend fun getMangaUpdate(
        manga: SManga,
        chapters: List<SChapter>,
        fetchDetails: Boolean,
        fetchChapters: Boolean,
    ): SMangaUpdate {
        // Keep both legacy requests anchored to the original SManga. The ABI
        // asset is intentionally dependency-light and does not pull
        // kotlinx.coroutines merely to parallelize two compatibility calls.
        // Request identity is the contract that matters here.
        val updatedManga = if (fetchDetails) {
            fetchMangaDetails(manga).awaitSingleCompat()
        } else {
            manga
        }
        val updatedChapters = if (fetchChapters) {
            fetchChapterList(manga).awaitSingleCompat()
        } else {
            chapters
        }
        return SMangaUpdate(updatedManga, updatedChapters)
    }

    override suspend fun getPageList(chapter: SChapter): List<Page> =
        fetchPageList(chapter).awaitSingleCompat()

    @Deprecated("Use the suspend API instead")
    fun fetchPopularManga(page: Int): Observable<MangasPage> =
        throw UnsupportedOperationException()

    @Deprecated("Use the suspend API instead")
    fun fetchSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): Observable<MangasPage> = throw UnsupportedOperationException()

    @Deprecated("Use the suspend API instead")
    fun fetchLatestUpdates(page: Int): Observable<MangasPage> =
        throw UnsupportedOperationException()

    val supportsRelatedMangas: Boolean
        get() = false

    val disableRelatedMangasBySearch: Boolean
        get() = false

    val disableRelatedMangas: Boolean
        get() = false

    suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> =
        throw UnsupportedOperationException("Unsupported!")
}

private suspend fun <T> Observable<T>.awaitSingleCompat(): T =
    suspendCoroutine { continuation ->
        val completed = AtomicBoolean()
        val values = ArrayList<T>(1)
        subscribe(
            { value ->
                if (values.isEmpty()) {
                    values += value
                } else if (completed.compareAndSet(false, true)) {
                    continuation.resumeWithException(
                        IllegalStateException("Observable emitted more than one value"),
                    )
                }
            },
            { error ->
                if (completed.compareAndSet(false, true)) {
                    continuation.resumeWithException(error)
                }
            },
            {
                if (!completed.compareAndSet(false, true)) return@subscribe
                if (values.isEmpty()) {
                    continuation.resumeWithException(
                        NoSuchElementException("Observable emitted no value"),
                    )
                } else {
                    continuation.resume(values.single())
                }
            },
        )
    }
