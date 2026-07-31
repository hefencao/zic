package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.asObservableSuccess
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.network.newCachelessCallWithProgress
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

    protected abstract fun popularMangaRequest(page: Int): Request
    protected abstract fun popularMangaParse(response: Response): MangasPage

    override fun fetchSearchManga(
        page: Int,
        query: String,
        filters: FilterList,
    ): Observable<MangasPage> = Observable.defer {
        try {
            client.newCall(searchMangaRequest(page, query, filters)).asObservableSuccess()
        } catch (error: NoClassDefFoundError) {
            throw RuntimeException(error)
        }
    }.map(::searchMangaParse)

    protected abstract fun searchMangaRequest(
        page: Int,
        query: String,
        filters: FilterList,
    ): Request

    protected abstract fun searchMangaParse(response: Response): MangasPage

    override fun fetchLatestUpdates(page: Int): Observable<MangasPage> =
        client.newCall(latestUpdatesRequest(page))
            .asObservableSuccess()
            .map(::latestUpdatesParse)

    protected abstract fun latestUpdatesRequest(page: Int): Request
    protected abstract fun latestUpdatesParse(response: Response): MangasPage

    override fun fetchMangaDetails(manga: SManga): Observable<SManga> =
        client.newCall(mangaDetailsRequest(manga))
            .asObservableSuccess()
            .map { response -> mangaDetailsParse(response).apply { initialized = true } }

    open fun mangaDetailsRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    protected abstract fun mangaDetailsParse(response: Response): SManga

    override fun fetchChapterList(manga: SManga): Observable<List<SChapter>> =
        client.newCall(chapterListRequest(manga))
            .asObservableSuccess()
            .map(::chapterListParse)
            .map { chapters ->
                chapters.onEach { chapter -> prepareNewChapter(chapter, manga) }
            }

    protected open fun chapterListRequest(manga: SManga): Request = GET(baseUrl + manga.url, headers)
    protected abstract fun chapterListParse(response: Response): List<SChapter>

    override fun fetchPageList(chapter: SChapter): Observable<List<Page>> =
        client.newCall(pageListRequest(chapter))
            .asObservableSuccess()
            .map(::pageListParse)

    protected open fun pageListRequest(chapter: SChapter): Request = GET(baseUrl + chapter.url, headers)
    protected abstract fun pageListParse(response: Response): List<Page>

    open fun fetchImageUrl(page: Page): Observable<String> =
        client.newCall(imageUrlRequest(page))
            .asObservableSuccess()
            .map(::imageUrlParse)

    protected open fun imageUrlRequest(page: Page): Request = GET(page.url, headers)
    protected abstract fun imageUrlParse(response: Response): String

    fun fetchImage(page: Page): Observable<Response> =
        client.newCachelessCallWithProgress(imageRequest(page)).asObservableSuccess()

    suspend fun getImage(page: Page): Response =
        client.newCachelessCallWithProgress(imageRequest(page)).awaitSuccess()

    protected open fun imageRequest(page: Page): Request = GET(requireNotNull(page.imageUrl), headers)

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
    open fun prepareNewChapter(chapter: SChapter, manga: SManga) = Unit
    override fun getFilterList(): FilterList = FilterList()

    override val supportsRelatedMangas: Boolean
        get() = false

    override suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> =
        client.newCall(relatedMangaListRequest(manga))
            .awaitSuccess()
            .use(::relatedMangaListParse)

    protected open fun relatedMangaListRequest(manga: SManga): Request =
        error("Related manga is not supported")

    protected open fun relatedMangaListParse(response: Response): List<SManga> =
        error("Related manga is not supported")

    override val disableRelatedMangasBySearch: Boolean
        get() = false

    override val disableRelatedMangas: Boolean
        get() = false
}
