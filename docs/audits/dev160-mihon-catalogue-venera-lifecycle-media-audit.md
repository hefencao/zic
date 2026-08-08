# dev.160 Mihon目录、Venera生命周期与媒体网络审计

## 基线与参考

- 唯一代码基线：dev.159完整交付包。
- Mihon接口参考：用户提供的 `mihon-main(3).zip`，只读。
- 旧设备trace只用于定位历史回归模式，不作为dev.159当前设备结论。

## 根因

1. ZIC runtime16 `CatalogueSource.getMangaUpdate`曾把 `fetchMangaDetails`结果再传给 `fetchChapterList`；当前Mihon使用原始SManga分别获取详情/章节。该差异可改变扩展请求identity。
2. source settings和Venera Web登录已经能在当前runtime更新，却又被App提升成runtime replacement；同时生产plugin process沿用默认8-session上限，都会放大“插件掉线”。
3. shared media transport曾固定Venera UA并把2xx响应直接当媒体；Mihon source.client语义无法总由Dart HttpClient静态request plan完整重放，2xx HTML/拦截页会进入decoder。
4. Mihon details/chapter durable manifest无本轮接口revision，旧错误目录可跨升级继续命中。

## 收口

- exact CatalogueSource original-SManga contract；legacy fallback同样使用原始manga。
- settings/Venera login原地；Mihon browser restart专用API；生产session上限32。
- 删除共享Venera UA；非媒体2xx在Pipeline前切到已有source-owned compatibility path。
- Mihon details/chapter metadata升revision。
- Cloudflare不改。
