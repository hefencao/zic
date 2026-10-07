# ADR 0068：Mihon runtime transform、组合目录与详情元数据

## 状态

接受，取代 dev.81 中“所有 Mihon 图片均可由宿主 URL/headers 直连”的过度假设，并修正 dev.83 详情元数据缺口。

## 背景

Mihon `HttpSource` 的最终图片语义不只包含 URL 和 headers。扩展可以通过其 `OkHttpClient` 的 interceptor、cookie jar、authenticator 或 DNS 实现响应转译。JMComic/18comic 的静态正文反混淆即属于这一类。绕过 source client 会得到合法但被分片扰乱的单帧 WebP。

Mihon 1.6 同时以 `getMangaUpdate(...): SMangaUpdate` 原子返回详情和章节。宿主在取得非空 `SMangaUpdate.chapters` 后再次调用 `get/fetchChapterList` 会重复执行插件操作并破坏非幂等来源。

## 决策

1. `plugin_host_bridge` 检查 source client 的网络能力。存在由扩展 classloader 拥有的 interceptor、network interceptor、cookie jar、authenticator、proxy authenticator 或 DNS 时，request plan 标记 `requiresRuntimeTransform=true`。
2. 无自定义能力的普通 Mihon 图片继续由宿主 transport 流式下载；需要转译的图片由隔离 runtime 使用 source client 得到正确响应 bytes，再进入同一 DownloadSession/Pipeline。transform 版本进入 chapter source revision，使 dev.81–83 的未转译 artifact 不再命中。App/Reader 不实现来源专用反混淆。
3. `SMangaUpdate.chapters` 非空时为权威章节目录。只有组合 API 缺失或未返回章节时才调用旧 chapter-list API。
4. bridge 将 `SManga.description`、`getGenres()/genre` 和可读 source name 翻译到稳定 domain/catalog metadata。数字 source identity 不得作为显示名称。
5. tags 随 Comic、SourceComicSummary、SavedComicRecord 和 ImportedChapterRecord 持久化；详情和 adaptive 只读消费。
6. 详情页只用 source chapter 已知页数或同 chapter identity 的持久 page list；不得为页数后台遍历正文。
7. restored/promoted transfer UI 由纯 snapshot projection 决定，测试不得依赖 Widget teardown 或文件生命周期。

## 后果

- 需要 source client 转译的扩展可能无法在转译前获得网络流式首帧，但正文正确性优先；普通来源仍保留宿主流式。
- runtime transform 选择是插件能力决策，不是 URI scheme 或 App 页面决策。
- 章节目录不再产生组合更新后的重复插件请求。
