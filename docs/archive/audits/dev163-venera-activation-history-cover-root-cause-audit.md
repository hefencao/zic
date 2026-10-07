# dev.163 Venera activation 与阅读历史封面根因审计

## 输入与边界

- 唯一代码基线：`zic_v0.31.0-dev.162_source-resource-atomic-catalog-boundary.zip`。
- 设备现象：`venera:ehentai` 激活抛出 `ExternalPluginActivationException(... activationFailed)`，底层为 `PlatformException(runtime-service-died...)`；阅读历史封面偶发空白，Reader 返回更新阅读进度后有时重新出现。
- 本轮不修改 Mihon/Cloudflare，不恢复 artwork timer/retry/watchdog/ImageCache eviction，也不新增 App 私有 cache/Future join。

## Venera activation 根因

`AndroidVeneraSandboxRuntimeBackend.activate()` 在 dev.162 直接调用 `_activatePlatformRuntime()`。后者只执行一次 `MethodChannel.activateVeneraRuntime`；若 Android runtime service 在该 pending call 期间死亡，`PluginRuntimeServiceClient` 会把 binding 标记 lost、清理旧 service并以 `runtime-service-died` 失败当前 call。

同一文件中，**activation 成功后的** `_PlatformExternalPluginRuntimeMessageChannel.send()` 已把 `runtime-service-died/disconnected` 视为可恢复 runtime 生命周期错误，并通过 `_recover()` 重新 activation 后重放 invocation。因此缺口只发生在“首个 session 尚未建立”的 activation 边界。

修复是在 bridge 基础设施边界对 `runtime-service-died/disconnected` 重放 activation **一次**。第二次失败继续向上返回；`runtime-request-invalid` 等插件/业务错误不重放。production controller 原本已设置 `quarantineActivationFailures: false`，因此本轮不修改插件 quarantine 语义。

## 阅读历史封面：根因链

### 1. 最初空白的确定性代码根因：source-ready 依赖没有进入封面 State

Home 为了不让插件启动阻塞首屏，会先用 durable library primary 数据呈现历史/更新；external plugin controller 则在 `ready` 后才通过 `_replaceExternalSources()` 增量接入 active source。

Artwork gateway 本身的顺序是正确的：先做 source-independent durable cache probe；只有 miss 后才 `_requireSource(sourceId, uri)`。问题出在这两条正确策略的交界：

1. 冷启动时某个外部封面 durable cache miss；
2. 对应 Venera/Mihon adapter 尚未进入 `_sources`；
3. `_requireSource()` 立即失败；
4. dev.162 `_CoverImage` 把这个 failed Future 保存在 State 中；
5. external plugin 后续 ready 会让 Home rebuild，但相同 cover identity 的 `_CoverImage.didUpdateWidget()` 不会重新执行 loader。

因此它不是“阅读历史没更新封面字段”，而是**封面加载真正依赖的 source availability 没有进入 State 的依赖集合**。普通 Home rebuild既不应也不会重试；但 source从 unavailable→available 是资源依赖真实变化，应该只在先前 source load失败时重新求值一次。

本轮给 Home/Shelf cover显式传递 `sourceAvailable`。`_CoverImage` 只在以下两类变化重新创建 source Future：

- canonical cache identity改变；
- 上一次 source阶段已经失败，且 live source从 unavailable变为 available。

成功的 warm durable cover在插件随后 ready时不会重载；阅读进度、Home enrichment、普通 parent rebuild也不会触发重载。

### 2. 为什么“进入 Reader 更新历史”会偶然把它带活

Home history 按 `ReadingProgress.updatedAt` 排序，Reader route 返回后 `replaceProgress()` 会改变历史 item 顺序。

dev.162 `_buildHorizontalComics()` 的 `ListView.separated` 又有第二个结构问题：Sliver直接 child是无 key `SizedBox`，稳定 key藏在内部 `ComicCoverCard`，且没有 child-index映射。重排时原 cover State可能丢失并被重新创建；这会**偶然重新执行第 1 节已经失败并锁住的 source Future**。于是表象就变成“阅读历史更新后封面出现”。

本轮将 `section + canonical comic identity` key提升到 Sliver直接 child，并提供 separated child-index映射。阅读进度仍只决定排序/继续位置，不进入 cache identity或 source availability。

### 3. 当前 trace 对两类失败的支持与边界

用户上传的 dev.162 trace 同时存在：

- `homeCoverRequested` 后没有 `homeCoverSourceReady` 的条目；这与上述 startup source-unavailable/failed-Future链一致，但 dev.162没有 source failure事件，无法逐卡证明具体异常类型；
- `homeCoverSourceReady(durableCacheFile)` 后没有 `homeCoverFirstFrame` 的条目；这**不能**直接判定 decoder失败，因为旧 telemetry owner在更新/历史间共享，而且离屏 child也可能没有 first-frame。

因此本轮新增：

- `homeCoverSourceFailed`：记录 error type和失败时 `sourceAvailable`；
- `homeCoverDecodeFailed`：只有 Flutter ImageStream明确报错才记录；
- section-aware identity：`home-update:*` / `home-history:*`。

下一份真机 trace中，`homeCoverSourceFailed{sourceAvailable:false}` 将直接验证 startup source-ready链；`homeCoverDecodeFailed` 才能证明 durable file/provider到 decoder这一段另有问题。不会用“缺 first-frame”猜 decode，也不恢复 artwork timer/watchdog/evict。

## 所有权结论

- 阅读进度：`HomeLibrarySession` 的 progress projection，只决定历史排序/继续位置。
- artwork response/cache：`ComicSourceResourceGateway` + `ResourceCacheManager`，未改变。
- cover presentation state：稳定 canonical identity；列表重排不得销毁它。
- Venera runtime service恢复：`plugin_host_bridge`，不是 Venera source业务层，也不是 App retry。

## 验证限制

当前执行环境无 Flutter/Dart SDK，无法运行新增 Flutter tests/analyzer。静态门禁和 Python结构检查可以执行；基线缺少 pinned `third_party/source_archives/libwebp-1.6.0.zip`，dev.98/source build gate按既有规则不能在此环境完成。
