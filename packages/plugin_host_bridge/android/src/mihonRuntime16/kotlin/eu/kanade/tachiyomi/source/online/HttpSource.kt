package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import java.net.URI
import java.net.URISyntaxException
import java.security.MessageDigest
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import rx.Observable
import uy.kohesive.injekt.injectLazy

abstract class HttpSource : CatalogueSource {
    protected val network: NetworkHelper by injectLazy()
    abstract val baseUrl: String
    open fun getHomeUrl(): String = baseUrl
    open val versionId: Int = 1

    override val id: Long by lazy {
        val key = "${name.lowercase()}/$lang/$versionId"
        val bytes = MessageDigest.getInstance("MD5").digest(key.toByteArray())
        (0..7)
            .map { bytes[it].toLong() and 0xff shl (8 * (7 - it)) }
            .reduce(Long::or) and Long.MAX_VALUE
    }

    val headers: Headers by lazy { headersBuilder().build() }
    open val client: OkHttpClient
        get() = network.client

    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().apply {
        add("User-Agent", network.defaultUserAgentProvider())
    }

    override fun toString(): String = "$name (${lang.uppercase()})"

    override fun fetchPopularManga(page: Int): Observable<MangasPage> =
        client.newCall(popularMangaRequest(page))
            .asObservableSuccess()
            .map(::popularMangaParse)

    protected open fun popularMangaRequest(page: Int): Request =
        throw UnsupportedOperationException()

    protected open fun popularMangaParse(response: Response): MangasPage =
        throw UnsupportedOperationException()

    override fun fetchSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): Observable<MangasPage> = client.newCall(searchMangaRequest(page, query, filters))
        .asObservableSuccess()
        .map(::searchMangaParse)

    protected open fun searchMangaRequest(
        page: Int,
        query: String,
        filters: FilterList,
    ): Request = throw UnsupportedOperationException()

    protected open fun searchMangaParse(response: Response): MangasPage =
        throw UnsupportedOperationException()

    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> =
        client.newCall(latestUpdatesRequest(page))
            .asObservableSuccess()
            .map(::latestUpdatesParse)

    protected open fun latestUpdatesRequest(page: Int): Request =
        throw UnsupportedOperationException()

    protected open fun latestUpdatesParse(response: Response): MangasPage =
        throw UnsupportedOperationException()

    override fun fetchMangaDetails(manga: SManga): Observable<SManga> =
        client.newCall(mangaDetailsRequest(manga))
            .asObservableSuccess()
            .map { response -> mangaDetailsParse(response).apply { initialized = true } }

    open fun mangaDetailsRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)

    protected open fun mangaDetailsParse(response: Response): SManga =
        throw UnsupportedOperationException()

    override val supportsRelatedMangas: Boolean
        get() = false

    override suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> =
        client.newCall(relatedMangaListRequest(manga))
            .awaitSuccess()
            .use(::relatedMangaListParse)

    protected open fun relatedMangaListRequest(manga: SManga): Request =
        throw UnsupportedOperationException()

    protected open fun relatedMangaListParse(response: Response): List<SManga> =
        throw UnsupportedOperationException()

    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> =
        client.newCall(chapterListRequest(manga))
            .asObservableSuccess()
            .map(::chapterListParse)

    protected open fun chapterListRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)

    protected open fun chapterListParse(response: Response): List<SChapter> =
        throw UnsupportedOperationException()

    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> =
        client.newCall(pageListRequest(chapter))
            .asObservableSuccess()
            .map(::pageListParse)

    protected open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)

    protected open fun pageListParse(response: Response): List<Page> =
        throw UnsupportedOperationException()

    open fun fetchImageUrl(page: Page): Observable<String> =
        client.newCall(imageUrlRequest(page))
            .asObservableSuccess()
            .map(::imageUrlParse)

    open suspend fun getImageUrl(page: Page): String =
        fetchImageUrl(page).toBlocking().single()

    protected open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)

    protected open fun imageUrlParse(response: Response): String =
        throw UnsupportedOperationException()

    protected open fun imageRequest(page: Page): Request =
        GET(requireNotNull(page.imageUrl), headers)

    fun SChapter.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    fun SManga.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    private fun getUrlWithoutDomain(original: String): String {
        return try {
            val uri = URI(original.replace(" ", "%20"))
            buildString {
                append(uri.path)
                uri.query?.let { append('?').append(it) }
                uri.fragment?.let { append('#').append(it) }
            }
        } catch (_: URISyntaxException) {
            original
        }
    }

    open fun getMangaUrl(manga: SManga): String = mangaDetailsRequest(manga).url.toString()
    open fun getChapterUrl(chapter: SChapter): String = pageListRequest(chapter).url.toString()

    @Deprecated("All modifications should be done when constructing the chapter")
    open fun prepareNewChapter(chapter: SChapter, manga: SManga) = Unit
}
