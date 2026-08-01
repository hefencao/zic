## dev.84 完成项与后续设备验证

已实现 Mihon source-client transform capability、`SMangaUpdate` 章节权威采用、source name/description/tags 翻译与持久化、详情 UI 调整和持久页数回填。下一步在设备上验证 JMComic 静态反混淆、普通 Mihon 宿主流式不退化、插件重进后的章节目录和 tags/source 名称。

## dev.83 完成项与后续设备验证

- [x] 所有 source kind 合并到稳定 7/3、2/1、5/3/2 profile，并删除无生产调用的 profile aliases。
- [x] 迁移 VibeVenera adaptive model v4 的 portable metadata/geometry/animation 逻辑并持久化 per-comic profile。
- [x] 统一 stitched DPR extent、direct texture fill 和共享 paint boundary。
- [ ] 在 Flutter/Android 环境运行 analyzer、owner tests、App tests、kernel snapshot 和 debug/release。
- [ ] 真机验证章节中部 policy 为 11 downloads/4 decodes，且预下载页面在进入 viewport 前已 receiving/sealed。
- [ ] 在多个 DPR 和缩放/惯性滚动位置验证连续接缝始终为 0 像素。

## dev.82 completed

- [x] 从 20000 条设备 Trace 统计每 identity 的 chunk、decode、upload 与 frame 有效产出，确认下载完成后 frame consume 缺少独立 decode wake。
- [x] 将 WebP 子矩形合成迁回源 canvas，整帧一次缩放。
- [x] 分离 source-revision wake 与 frame-consumed wake，并以 snapshot 变化门控下游。
- [x] 在 DownloadSession 聚合 committed-byte telemetry，并将 raw export ring 默认上限调整为 10000。
- [x] 修复 controlled transport close 死锁与几何精确浮点测试。
- [x] 增加 ADR 0066、dev.82 审计/门禁并更新文档。
- [ ] 在 Flutter/Android 环境运行 analyzer、真实 Dart/Flutter tests、Rust tests 和 APK 构建。
- [ ] 真机复验截图对应 WebP 的条带、完整下载后的持续播放和长时间 Trace 体积。

## dev.81 completed

1. 从 2032 条设备 Trace 区分缓存分块复制与 Mihon origin 完整 blob：将 Mihon 正常正文改为 request-plan + host streaming，保留失败后兼容 fallback。
2. 将网络 run partial baseline 收回 DownloadSession，并修正 current-page progress projection。
3. 延迟 platform upload slot retirement 到 active Future 排空；拒绝 stale revision 的 success/failure 回写。
4. 章节入口改为 route-first deferred Reader，并把准备工作移入 route。
5. 将连续阅读 gap/anchor 算法拆为 `ReaderVerticalGeometry`，删除 downloads/App 真实 socket、`pumpAndSettle`、固定 400ms、lazy child 与魔法 offset 测试。
6. 修复 Android Activity Result API 编译闭包、统一 media centering，更新 ADR/文档/静态门禁并完成当前环境可执行契约验证。

Next validation: 在具备 Flutter/Android 工具链的机器上运行 analyze、受影响 package tests、App tests 与 APK/kernel build；真机验证 Mihon origin 首 chunk、未知长度进度、快速 30↔31 页切换动画、章节点击到 route 的时延和 WebP 居中。

## dev.80 completed

1. Add monotonic ingress revision tracking and drain source updates through one DecodeId-owned follow path without duplicate latest-revision work.
2. Project unknown-length transfer as connecting or receiving from real committed-byte movement; do not invent percentages.
3. Introduce one aligned raster value object and make static images, DecodeTarget and native WebP use the same contain/aspect/8-pixel contract.
4. Centralize Presentation fit in `MediaAspectViewport`, preserve requested fit before intrinsic dimensions resolve, and keep header dimensions authoritative over output buffers.
5. Replace Android `file_selector` save with an App-owned SAF exporter; bound clipboard JSONL independently and report both failures.
6. Add owner tests, ADR 0064, dev.80 audit/static gate and local libwebp validation without changing windows or lanes.

Next validation: run Flutter analyze and all owner/App tests, Rust tests, Android debug/release or kernel snapshot. On device use a WebP whose first complete frame arrives before EOF, confirm first frame appears while bytes still increase, compare wide/tall static and animated pages at several DPRs, and verify both copy and SAF JSONL export.

## dev.79 completed

1. Serialize Venera JavaScript source operations without changing Mihon concurrency or host streaming lanes, and remove the competing WebView raw `loadInfo` cache.
2. Route all source-owned absolute artwork locators through the composition gateway and coalesce the complete encoded-image cache resolution.
3. Project encoded source creation, growth, seal and failure through one DownloadSession lifecycle listener; make Decode/Upload terminate loading on authoritative failure.
4. Stabilize unknown continuous-page extents and use an idle top-pixel anchor that never competes with active scrolling.
5. Promote runtime-confirmed animation above source vertical hints while retaining explicit per-comic direction ownership.
6. Add owner tests, ADR 0063 and dev.79 static gates; preserve media windows and lane capacities.

Next validation: run Flutter analyze/package/App tests and Android debug/release. On device repeatedly refresh Venera details across runtime lifetime, restart Home with cold/warm custom-locator covers, verify partial Animated WebP starts before seal and resumes after scrolling away/back, confirm failures become visible, verify continuous scrolling does not pull back, and confirm adaptive animation switches to paged only after runtime/header evidence.

## dev.78 completed

1. Close the reported RendererKind and PlaybackState compile gaps at their real owners.
2. Treat native decode dimensions as aspect-preserving maximum bounds and propagate actual frame dimensions through upload/texture output.
3. Recreate an ended WebP cursor only across an empty-holder demand detach/re-entry boundary.
4. Remove all-chapter page-count body preflight and move read persistence off the Reader navigation critical path.
5. Split Debug Trace into bounded UI/raw rings and route copy/export through an injectable, failure-reporting file capability.
6. Add owner tests, ADR 0062 and a dev.78 static boundary gate without changing windows or lanes.

Next validation: run Flutter analyze/package/App tests and Android debug/release. On device verify representative wide/tall pages, scroll away/back replay, selected-chapter entry latency, raw JSONL export size and save-provider behavior.

## dev.77 completed

1. Replace independent source-only composition with one `PipelineMediaRuntimeFactory` and a session-owned runtime.
2. Wire production SourcePool, DecodeRegistry, UploadRegistry, FrameBudgeter and LiveCoordinator from that same capability; preserve existing windows and lanes.
3. Add `pipeline_native` above the core boundary and keep `pipeline_runtime` free of bridge/texture dependencies.
4. Remove `PipelinePageStream.source`; expose opaque claimed output through `PipelinePageOutputStream` and migrate every Reader/App caller in one closure.
5. Move pause/speed and animation due-frame advance into Pipeline session ownership.
6. Add claim-safe per-DecodeId Android texture retirement and drain it before runtime close.
7. Add owner tests/static gates, update ADR/docs and validate the supplied libwebp 1.6.0 source locally.

Next validation: run Flutter analyze/tests and Android debug/release on an SDK-equipped machine; on device verify current/transition outputs, animated frame pacing, target replacement without flash, immediate route exit and texture-memory retirement. Non-WebP output unification remains a separate future design, not an excuse to restore direct Reader WebP decode.

## dev.76 completed

Boundary follow-up completed by dev.77 / ADR 0061.

1. Read the sole dev.75 baseline, current ownership documents, ADRs, device trace and read-only Mihon/VibeVenera references before editing.
2. Record compile/product/performance/test issues, authoritative owners and rejected regressions in `docs/audits/dev76-reader-exit-and-loading-ownership-audit.md`.
3. Remove Reader viewport loading state/overlay and the page-loading suppression compatibility API; keep first-frame telemetry in the Reader page host.
4. Add owner-package and Reader regressions plus a static ownership gate; audit all remaining centered progress indicators by scope.
5. Preserve Pipeline windows, lanes, source transport, GET/HEAD and cache behavior.

Next: run Flutter analyzer/package/App tests and Android debug/release in an SDK-equipped environment, then verify on device that vertical pages show exactly one image-local spinner and that the current-page WebP reports its first frame before or cleanly after immediate route exit.

## dev.75 completed

- Close all reported dev.74 compile/test API migrations.
- Move private transport tests to `pipeline_runtime` and remove obsolete App/Reader facades.
- Remove the unused local-details compatibility wrapper and test the actual owner.
- Add a compile/ownership migration gate and include every Flutter composition package in the shared analyze/test runners.
- Publish a reusable AI iteration prompt focused on Architecture and coupling.
- Preserve all Pipeline media policy and transport behavior.

## dev.74 completed

1. 修复 Dart library directive 顺序并建立门禁。
2. 统一连续 Reader 的 ratio 单位，删除拼接负位移，使用可定位 variable-extent list。
3. 将来源浏览与详情封面切换为文件型 encoded source，并拒绝持久化非图片响应。
4. 将 Debug Trace 从原始事件堆积升级为可筛选、可导出、有强调色的有界诊断投影。
5. 保持 Pipeline 预取与 lane 参数，不用退化策略掩盖 Presentation/缓存问题。

Next: 在 Android 真机验证保存页直接定位、不同 DPR 下无拼接接缝、封面 warm-start 命中和 JSONL 导出。

## dev.73 completed

1. Close all dev.72 package/type/API compile gaps.
2. Inject `SourceFactory` at platform composition instead of importing FFI bridge from Pipeline.
3. Remove artifact-cache and download-identity implementation knowledge from local media presentation.
4. Restore frame-coalesced page geometry projection.
5. Preserve dev.70/72 streaming, preload and scheduler behavior.
6. Add static compile-boundary regression and rebuild both full and incremental deliveries.

## dev.72 completed

- [x] Extract Reader resource ownership into `pipeline_runtime`.
- [x] Make Reader and local-media presentation consume read-only Pipeline streams.
- [x] Derive current-page transfer projection from Reader observations inside Pipeline.
- [x] Route Home/source/details artwork through one source request-plan transport and response cache.
- [x] Split Venera thumbnail resolution from chapter-page resolution and coalesce request plans.
- [x] Preserve dev.70 prefetch/decode/upload windows and lane concurrency.
- [ ] Validate actual Android process Tx/Rx bytes with device traffic tooling and correlate them with sanitized request counters.

# zic Implementation Plan

## 1. 实施原则

- 先建立可测状态机，再接入真实网络和 decoder。
- 先实现 deterministic heuristic，再实现 adaptive policy。
- 先完成 Android 性能闭环，再做 iOS parity。
- 每个阶段都有可运行 vertical slice，不长期维护不可运行大分支。
- 所有优化都要有 trace 和基准。

## 当前 fixed-overlay dev.21 候选收敛门禁

- 唯一基线是上一完整候选与 `fixed.zip` 五文件覆盖后的合并树，映射和 ingress
  hash 记录于 `docs/FIXED_OVERLAY_BASELINE.md`。
- 普通 WebP 打开固定从 Flutter codec 开始，native 必须显式二次确认。
- picker、route、容器校验、codec 页面状态和文件夹切换分别测试。
- 异步测试同步到 `WebpPreviewState` 或受控 future，不推进猜测的固定 frame 时长。
- Reader app 使用 `LiveCoordinator + DownloadRegistry`，播放器只读取 promoted
  artifact；viewport 重建或销毁前必须 detach 旧 demand plan。
- 导入文件夹必须归一化为 catalog chapter record，并通过 loader transport 和
  DownloadSession 进入 Reader；记录与最后阅读位置由持久目录库保存，禁止保留独立目录浏览器的直接文件读取权威。
- 本地目录递归枚举不得在 UI isolate 执行，只创建当前可见图片的播放器；Android 必须沿 SAF document tree/content URI grant 读取，桌面使用 isolate 文件扫描；格式由文件头嗅探，完整 codec 负责最终校验。

## 当前应用主线（0.31.0-dev.72）

- 来源私有资源的 App 组合只允许通过 `ComicSourceResourceGateway -> ChapterResourceAccess` 一次性绑定；禁止 Home/UI 直接持有 transport pool 或分别设置 loader/transport。
- gateway 生命周期必须先解绑外部下载服务再关闭 transport，防止持久服务保留失效回调。
- Venera 主线采用 request-plan/body 分离：插件解析 URL/header/callback，ZIC Transport/DownloadSession/Artifact 承担流式正文、resume、进度和缓存。
- 预取不得再次退化：下载窗口固定 +7/-3，预解码 +2/-1，只上传 current/transition；network/decode/upload lane 为 5/3/2，JavaScript request-plan 保持串行。
- 下载管理与 Reader 进度只能投影 authoritative session；完成/restore 页面不显示网络态，chunk 到达后必须可见真实进度。
- Android 实机验证重点是 GET 零 body、onImageLoad 调用次数、正文下行、请求上行、首 chunk/首帧时间和 detach 后连接保留/显式取消。

- 完成第四根导航“杂项”，将快捷设置、完整设置、关于和 Debug trace 从 Home 主线分离。
- 设置按数据/网络/书架/阅读/下载/外观分层；所有可执行项复用既有 store、queue、cache coordinator 与 Reader composition。
- App 小型偏好通过 `storage_bridge` 注入式 map 读写持久化，禁止 `apps/app` 直接导入 `dart:io`。
- 下一步补齐目录迁移/恢复协议与数据备份导入；不得在未定义索引和 artifact 迁移前允许任意修改根目录。

- Mihon extensionLib 1.4/1.5/1.6 必须映射到版本化 Source ABI asset；不得把任一 `extensions-lib` 放回 App runtime classpath，也不得回退为 parent-first Source API。
- Mihon 章节目录必须保留来源返回的全部真实 `SChapter`；单章节兜底仅允许在目录为空时创建。详情到阅读之间优先保留原始章节对象，重启恢复只能按稳定来源身份重新匹配，不得把漫画 URL 或第一章复用于所有章节。
- Venera `settings` 必须通过统一 `ConfigurableComicSource` 映射到设置页并保持类型化持久化；设置 bridge 仍受已批准 `persistentStorage` capability 约束，Presentation 不直接读写插件存储。
- Venera 外层 invocation timeout 必须覆盖 native connect/read 上限但不超过平台上限；来源脚本不得被宿主强制 strict mode，legacy `res` 兼容只位于 sandbox bootstrap。
- 目标重建回归必须先证明 decode target 实际变化；仅改变容器尺寸但 raster target 不变时，不得把“不重建 codec”判定为产品错误。
- Mihon/Venera activation wire 必须在隔离进程入口再次严格解析；process-side driver 不得直接信任 host 进程中的对象或未声明字段。
- 批准 payload 必须在隔离进程内按 length/SHA-256 流式重验并原子提升为 process-private 文件，driver 只能打开该副本；session 关闭后由 process host 删除。
- runtime process host 必须拥有 session registry、activation 串行化、invoke/cancel/close 路由和 joinable shutdown。进程死亡/重启后不得自动重放中断的 catalog 请求。
- dedicated Android runtime service 只允许转发 `ExternalPluginRuntimeServiceMethods` 的原始 wire message；activation、payload staging、session registry、取消和 shutdown 必须由 Dart service endpoint/process host 统一拥有，不得在 Kotlin 重复实现。
- Android runtime Service 必须 `exported=false` 并运行在 `:zic_plugin_runtime`。FlutterEngine 禁止自动 plugin registration，只执行保留的第二 Dart entrypoint；Mihon/Venera driver 仅在该专用进程注册，未知格式或不兼容 ABI 必须返回明确错误，禁止主进程回退。
- Host/Service 跨进程调用不得依赖 Binder 携带大型页面字节。请求必须保持小型且有界；大响应写入应用私有原子 packet，host 校验 canonical root/exact length/SHA-256 后读取并删除。service death 只失败当前调用，不自动重发、重激活或复用旧 generation。
- 每个 runtime service process 必须生成新的 `processId`。invoke/cancel/close 同时校验 process/session identity；进程重启后旧 generation 必须失败，禁止透明重激活或请求重放。
- 普通本地静态图片的文件路由必须是可独立验证的纯映射；zero-Dart-copy 测试不得启动宿主平台 codec 或依赖测试 runner 的图片流收尾。
- 受控 GIF/WebP 状态机只依赖 `FlutterAnimatedCodec` 契约。生产 adapter 使用 `ui.instantiateImageCodec`，测试 adapter 必须确定性返回帧；不得让不可取消的 engine Future 成为状态机单元测试前提。
- 动画首帧 ready 必须等待真实 `endOfFrame`。替代 decode target 未呈现前保留旧帧；generation 失效或 dispose 时必须释放新旧 frame、codec 和 Timer，失败断言也必须执行同一 teardown。
- `local_image_preview_test.dart` 和冷 Reader artifact 测试使用有真实时间上限的事件循环轮询，而非固定帧数推断外部 I/O/codec 已完成。
- 将 protocol-v1 的服务端所有权收敛为 `ExternalPluginRuntimeWorker`：隔离边界内再次解析请求、验证 source/request identity、净化错误、跟踪真实调用并确定性关闭。
- 为 raw runtime channel 增加可选的 request-level cooperative cancellation；timeout 只结束调用者等待，底层 Future 退出前 host permit 不释放。
- Mihon/Venera activation envelope 传递 exact payload path/length/hash、approved capabilities 和 runtime limits；Android host adapter 统一 activation/invoke/cancel/close。
- Android native bridge 仅在 `:zic_plugin_runtime` 内加载已验证的 Mihon APK 或执行受限 Venera JavaScript；不得退回主进程 class loading 或无约束脚本执行。
- 生成 Android host 的依赖仓库配置属于 App runtime classpath 所有者：优先 `dependencyResolutionManagement.repositories`，否则 `allprojects.repositories`。插件子工程局部 repository 不能被当作 App 解析闭环；canonical JitPack 配置必须幂等并兼容 Groovy/Kotlin DSL。
- Mihon `extensions-lib` 只提供动态扩展所需 ABI，必须以 `transitive = false` 接入；其旧 POM 依赖不得与当前 Keiyoushi common bundle 并存。AndroidX Preference 与 Injekt 各自只能有一个宿主提供者，禁止通过关闭 duplicate-class 检查或 packaging pickFirst 绕过。
- 动态加载 APK 对宿主类的引用对 R8 不可见。plugin bridge 必须向 App 发布 consumer keep 规则，并在 activation 前预检核心 Source/模型、Preference 与 Injekt ABI；缺失必须明确失败，禁止延迟为空目录或模糊反射错误。
- Mihon 扩展实例化必须使用已验证 process-private APK 的 payload Context，而不是 ZIC 应用 Context。包名、资源/assets、class loader、LayoutInflater、偏好与文件目录必须指向扩展隔离域；入口需兼容 Kotlin object、静态工厂、Context 和无参构造，并把入口类名与根因跨进程保留到 activation 诊断。
- Venera browse 适配必须归一化当前 `explore` loader 容器和 `category.parts[].itemType/categories/categoryParams`，同时保留旧 `target.attributes`。网络桥只能协商实际可解码的 content encoding；公共域名被系统 DNS 映射到非公共地址时，回退只能接受 DoH 返回的 A/AAAA 公网地址并保持原 hostname TLS，禁止访问回环/私网或把 CNAME 当作地址解析。
- 持久插件 manifest 只能恢复 `external_plugins` 私有根下的普通、非链接、格式后缀匹配 payload。Mihon extraction workspace 必须按 activation `driverId` 隔离，关闭时在真实任务排空后才释放 source 和删除目录，Service 启动负责清理进程死亡遗留目录。
- Mihon/Venera driver 必须复用现有 worker、protocol-v1、session/cancel/limit 所有权。新增生态 API 时只扩展隔离 adapter，不复制 catalog/domain 映射，也不得绕过 payload pin、签名/ABI/source-key 或用户信任。

- 保留 Home/Bookshelf 的 Presentation 拆分，但禁止在 `apps/app/lib` 定义资源缓存、章节下载、页面保活或整本调度算法。
- `resource_cache` 继续统一管理封面/图片响应、漫画详情、章节元数据和搜索结果。只有完整 `imageBytes` 可通过注入的 byte store 持久化；章节页面仍不进入该平面。
- 封面持久键必须包含完整 `ResourceCacheKey` 与可用 `sourceRevision`，保留命名空间失效、TTL、容量限制和显式刷新。关闭缓存时先停止接收新工作，再排空已有请求及持久提交；统一维护需分别展示/整理内存响应、持久响应和页面 artifact。
- Reader 的页面/缩放 host 按稳定 asset identity 建立。翻页中点改变 current role 只能触发状态更新和缩放重置，不得销毁已加载媒体子树；Presentation 仍不得通过 keep-alive、私有 LRU 或相邻页预热竞争 pipeline policy。
- `downloads` 管理独立页面 artifact 下载、promoted handoff 及整本队列；不完整章节继续由“章节元数据 + 任意页面 artifact 子集”表示。
- `catalog` 提供 Mihon repository 与 Venera source index 的纯元数据兼容层。Mihon 同时解析当前 `extensionList.extensions` v2 对象和旧版数组；Venera 同时兼容 `filename`/`fileName` 并优先保留仓库 `key`。host 必须检查 `tachiyomix.extensionLib` 等 APK ABI 元数据；外部 APK/Kotlin 与 JavaScript 执行分别位于受限 host，返回有显式 `close()` 生命周期的普通 `BrowsableComicSource`，不得获得导航、Reader、demand 或 artifact 权限。
- 外部插件的共享信任/权限/版本/ABI/隔离/session 门禁及 immutable-payload inspector 已实现；Android `MihonApkMetadataReader` 同时返回入口类元数据。Mihon/Venera 现共享版本化 browse/detail/chapter/resource wire protocol 和统一 `BrowsableComicSource` 适配层；host 对 timeout、响应字节和真实并发二次限流。现已在对应 isolated backend 内实现 class loader 与 JavaScript engine；后续兼容扩展仍不得复制 catalog/domain 映射或泄漏 Reader/download/artifact API。
- Reader 快速切页 trace 已有确定性回放分析：由 `downloads` 生成精确 page/DownloadId identity，分别记录 transition revision 与实际产出呈现帧的 work revision，还原 artifact 来源、decode/upload 排队与执行、present、first frame 和 host remount；中点前已呈现的邻页计为零 transition wait。任何 retention 调整必须先由该分析定位 owner，再在 pipeline/session/media 层实施。
- App durable composition 只接受显式 `ManagedChapterDownloadService` 作为页面 artifact store/maintenance；普通 `ChapterDownloadService` 保持较窄契约，避免把缓存维护强加给仅提供下载命令的适配器。
- 冷启动 Reader 命中已 promoted 页面 artifact 时，权威替代 session 进入 queued/receiving 即启动唯一精确读取；页面消费者只加入该读取并可立即 decode，替代 session 仍需完成 receive/seal/promote。禁止页面自行创建缓存/网络 demand 或新增 Presentation 私有缓存。
- Flutter 动图 `ready` 只能表示真实首帧已呈现，容器解析或 codec 创建不得提前发布 ready。仅因 decode target 改变而重建 codec 时必须保留最后呈现帧，直到替代帧真正呈现；encoded identity 改变时才立即清空。
- 首页冷启动必须先挂载 Flutter bootstrap surface，再异步打开持久服务；禁止在 `runApp` 前遍历恢复所有离线页面。read-state 使用单次批量查询，首页下载状态使用一次 index-only bulk projection，不得为徽标创建 session 或触碰页面文件；精确页面命令才 materialize/restore session。
- 完整封面 warm hit 和普通本地静态图片优先传递不可变文件引用到 engine-facing ImageProvider，避免整文件进入 Dart heap。`content://`、动画和 Reader 页面继续使用各自受控字节/session 边界；不得把“避免 Dart copy”夸大为平台解码绝对 zero-copy。
- Mihon/Venera inspector 必须针对同一不可变本地 payload 做实际长度和流式 SHA-256 检查。Mihon 元数据读取不得 class-load APK；Venera source key 发现不得执行 JavaScript，仓库 key 与脚本 metadata 必须一致。
- 普通本地静态图片只能由 engine-facing `Image` 持有一个 `ImageStream`；不得为了观察 ready 再手动 `resolve` 同一 provider。ready 由 `frameBuilder` 的实际帧发布，文件路由测试只验证不进入 Dart 整文件字节路径并必须显式卸载。
- promoted artifact 共享读取以权威 `DownloadSession.beginRun` 为最早启动信号，允许在临时 workspace restore 期间读取持久 artifact；页面仍只能 join，不能自行触发 cache/network demand。
- Mihon/Venera isolated backend 必须通过 `ExternalPluginRuntimeMessageChannel` 交换 protocol-v1 基础值/`Uint8List` 消息。handshake source identity、schema 和每次 response requestId 在跨边界处验证；不得返回进程内 zic domain/session 对象。
- Android bound-service transport 必须以 binding generation 区分每次显式连接，并通过 Binder death recipient 失败当前请求；旧 generation 的迟到回调不得拆除新连接，也不得自动 replay/activate。packet response 必须校验 dedicated root、exact length 与 SHA-256，消费或失败后删除。



### dev.72 当前主线约束

1. `pipeline_runtime` 是 Reader 资源会话唯一组合所有者；Reader 不得创建、关闭或直接访问下载、artifact、transport、decode/upload lane。
2. Reader 只能提交 `ReaderObs` 和消费只读 `PipelinePageStream`/progress；当前页传输选择必须由 Pipeline 从 observation 派生。
3. Home、来源浏览、详情页和迁移对比的远程 artwork 必须共用 `ComicSourceResourceGateway`、source transport 与 response cache。
4. Venera HTTP artwork 优先 `onThumbnailLoad`，durable chapter locator 使用 `onImageLoad`；同 locator request plan 必须并发合并并有界缓存。
5. 不得为降低流量再次缩小 +7/-3 下载、+2/-1 预解码或 5/3/2 lane。设备流量结论必须来自真实 Android Tx/Rx 计数与净化后的请求统计。


### dev.71 当前主线约束

1. `PersistentChapterDownloadService` 的来源资源配置必须以一个 `ChapterResourceAccess` 原子替换；不得在生产组合中分两次更新 loader 和 transport。
2. `ComicSourceResourceGateway` 是 App 唯一的 source-private resource gateway；Presentation 不得直接创建或关闭 `ExternalPluginResourceTransportPool`。
3. gateway 必须在关闭 transport 前解除已绑定下载服务；外部持久服务不得保留指向已关闭 gateway 的回调。
4. legacy loader/transport setter 只用于兼容第三方/测试实现；新生产调用方必须优先检查 `ConfigurableChapterResourceAccess` 并显式转换能力类型。
5. 章节下载/整本下载兼容动作属于 `_DemoHomeState` 的窄 extension，不得再把整个 State 传给全局 helper 访问私有所有者。


### dev.70 当前主线约束

1. 不允许通过缩小为“仅当前页”规避来源性能问题。Venera profile 必须保持稳定的 +7/-3 下载窗口、+2/-1 预解码和 current/transition 上传。
2. 插件 runtime 只拥有请求方案与来源回调；transport、partial artifact、resume、chunk progress、decode source 和 cache handoff 由 ZIC session 管线拥有。
3. JavaScript request-plan invocation 必须串行；network/decode/upload lane 并发不得反向提高 runtime 并发。
4. GET/HEAD 不得携带 body 或实体 headers。普通图片 body 不得经过 JSON/Base64/plugin RPC；只有显式 response transform 才允许 fallback。
5. normal detach 保留 receiving transport；显式取消必须终止 response subscription。任何 UI progress publisher 都不能改变 writer/session 生命周期。
6. 已 promoted 或仅 restore 的页面不得显示网络进度；章节进度必须在 chunk 到达时可观察，而不是完整页结束后跳变。


## 2. 阶段划分

## Phase 0：仓库与工程基线

### 目标

建立可持续迭代的 monorepo、CI、代码规范和性能基准入口。

### 任务

- 创建 Flutter app 和 Dart packages。
- 创建 Rust workspace 和 FFI smoke test。
- 配置 format/analyze/test。
- 配置 Android debug/release 构建。
- 配置 golden/performance test runner。
- 建立 ADR、错误码和日志 schema。
- 建立 fake clock、fake transport 和 deterministic scheduler。

### 验收

- Android 模拟器和真机可启动空应用。
- Dart 调用 Rust `zic_version()` 成功。
- CI 执行 Dart test、Rust test 和 Android build。

## Phase 1：Domain、Catalog 与静态 Reader Vertical Slice

### 目标

完成不含智能策略和动画 native 的最小阅读闭环。

### 任务

- 定义 Comic/Chapter/PageAsset/ReadingProgress。
- 实现本地目录和 manifest source。
- 实现 Reader LTR/RTL PageView。
- 实现 ReaderObs。
- 实现 Content/Download/Decode identity。
- 实现静态 ImageProvider 适配。
- 记录首帧和切页 telemetry。

### 验收

- 可加载 100 页本地章节。
- RTL/LTR 切换正确。
- 快速翻页无同步文件读取进入 build/raster。
- identity 和进度恢复测试通过。

## Phase 2：Transport、Artifact 与 DownloadSession

### 目标

建立统一编码字节权威和可恢复下载。

### 任务

- 实现 ComicSource/ByteStreamResponse。
- 实现 DownloadSession 状态机。
- 实现 writer lease 和 committedLength 校验。
- 实现 partial artifact、flush、seal、checksum、promote。
- 实现 SQLite cache index。
- 实现 range resume 和 validator 校验。
- 实现内容嗅探。
- 实现启动扫描和 orphan 安全规则。

### 验收

- 任意 chunk 边界写入正确。
- 进程中断后可恢复 partial。
- stale writer chunk 被拒绝。
- active artifact 不被扫描器删除。
- 无 range 来源普通 detach 不会自动重下。

## Phase 3：Pipeline、Role Window 与 Scheduler

### 目标

将 UI 状态转为统一 demand，并与 session 生命周期解耦。

### 任务

- 实现 PipelineController。
- 实现 PageRole、RoleResolver。
- 实现 HeuristicPolicy。
- 实现 ResourceRanker 和 PolicyGuard。
- 实现 DemandPlan/DemandDiff。
- 实现 Coordinator。
- 实现 network/decode/upload/maintenance lane。
- 实现 current reserve 和任务合并。

### 验收

- current/transition/near 角色在 trace 中正确变化。
- `onPageChanged` 前 target 可获得 transition demand。
- current 水位不足时 near 自动降级。
- UI helper 不拥有 session。
- 固定 Reader trace 产生确定性 DemandPlan。

## Phase 4：Rust Animated WebP Core

> 状态：`0.18.3-dev.21` 已完成增量 source、真实 WebP decode、frame ownership、
> blend/dispose、metadata、有限/无限循环、显式 cursor step，以及从固定上游源码生成 Android 三 ABI libwebp/media_core；
> Kotlin texture 与设备级生命周期测试仍继续推进。

### 目标

实现可增长字节源、native cursor 和 frame ownership。

### 任务

- 选择并封装 WebP 解码库。
- 实现 source create/append/seal/reset。
- 实现 source epoch 和 offset 验证。
- 实现 cursor create/decodeNext。
- 实现 frame retain/release/info。
- 实现 frame composition 和 loop metadata。
- 实现内存预算检查。
- 实现 Rust 单元和 fuzz 测试。

### 验收

- 分块输入与完整文件解码帧序列一致。
- 任意 chunk 边界不崩溃。
- stale epoch append/decode 被拒绝。
- frame 引用计数无泄漏。
- 受损文件返回结构化错误。

## Phase 5：WebP DecodeSession 与 Android Texture

### 目标

将 native frame 安全接入 Flutter 显示。

### 任务

- 实现 WebPDecodeSession。
- 实现 FrameHolder 和 frame depth。
- 实现 decode/upload claim。
- 实现 Kotlin texture registry。
- 实现专用串行 blit 线程。
- 实现 texture create 与 first blit 分离。
- 实现 scheduleFrame。
- 实现后台/前台和 texture release 排空。
- 实现 Flutter fallback renderer。

### 当前候选实现（仍需 Flutter/Android 验证）

- 已增加 `texture_bridge`、`SurfaceProducer`、串行 blit lane 和 JNI RGBA blit；
- external texture 使用源画布比例的 contain viewport，不直接拉伸到页面 viewport；
- 已建立 Dart 临时 owner 与平台当前帧 owner 的双层 retain/release；
- 已增加 queue/upload/deadline/memory/fallback telemetry；
- 已通过 `ReaderPageBuilder` 将 Animated WebP 播放器接入 Reader 页面；
- Reader demand 已由真实 `LiveCoordinator` 下载到 promoted artifact，asset/file/http
  transport 与 manifest `DownloadId` 共享身份；
- `DownloadSession` 提供 observer-safe snapshot，`ReaderBinding.detach` 清理旧计划；
- 已重构 picker、路由、容器校验和预览状态的测试边界。

此候选不得在目标 Flutter 测试、analyze、Rust/Android native 构建完成前升级版本
或标记为稳定基线。

### 验收

- 当前页 Animated WebP 可在下载封口前播放。
- PageView 停止后动画不停止。
- texture resize 不在每帧执行。
- release 不与在途 blit 竞争。
- 后台返回后 session 可继续或安全恢复。
- 三个指定 app 测试、完整 Flutter/Dart/analyze 和可用 native 检查全部通过。

## Phase 6：Transition、播放时序与缓存

### 目标

完成高质量切页、帧水位和多层缓存。

### 任务

- 实现 idle/dragging/overlap/dominant/settling。
- 实现 present freeze/resume。
- 实现未 present 帧时长重置。
- 实现 encoded memory cache。
- 实现 decoded frame cache。
- 实现 device budget resolver。
- 实现 CacheManager 和 safe eviction handshake。
- 实现 clear cache 异步流程。

### 验收

- transition 目标页 prepared 时无空白切换。
- cancel/reversal 不污染 current。
- 内存警告触发预算收缩，无 active 资源误删。
- cache clear 返回实际释放字节。
- 1000 页压力测试无持续增长泄漏。

## Phase 7：Telemetry 与 Heuristic 调优

### 目标

建立足够可靠的数据，证明策略效果并为学习准备。

### 任务

- 实现统一 event schema。
- 实现 monotonic trace。
- 实现 decisionId/policyRevision/epoch 归因。
- 实现性能 overlay 和 trace 导出。
- 实现 benchmark corpus。
- 调整 heuristic profile。
- 建立 current starvation、wasted bytes、present gap 指标。

### 验收

- 所有资源任务可追溯到 demand revision。
- stale result rejection 可统计。
- 同一 trace 可离线重放。
- heuristic 在目标 corpus 上达到性能门槛。

## Phase 8：Adaptive Policy Shadow

### 目标

模型只做影子决策，不影响真实资源。

### 任务

- 实现 FeatureBuilder 和 schema version。
- 定义有限 DemandProfile。
- 实现 LinUCB 或 Linear Thompson Sampling。
- 实现 PolicyModelStore。
- 实现 RewardAggregator。
- 实现 shadow decision 日志。
- 实现模型异常回退。

### 验收

- shadow 输出不改变实际 DemandPlan。
- 模型参数持久化和原子更新正确。
- 重复、旧 epoch 和超时 reward 被拒绝。
- 模型文件损坏时自动回退。

## Phase 9：受控在线学习

### 目标

在硬约束内让模型选择安全 profile。

### 任务

- 实现低比例安全探索。
- 当前页最低保障排除探索。
- 高温、低内存、计费网络关闭探索。
- 实现用户开关和模型重置。
- 实现 A/B 本地对比和回滚标志。
- 实现离线 replay evaluator。

### 验收

- 关闭模型时与 Phase 7 行为一致。
- 模型输出无法突破 PolicyGuard。
- 性能和资源指标不劣于 heuristic 门槛。
- 模型更新不会发生在每帧循环。

## Phase 10：GIF 与 iOS

### 目标

补齐格式和平台能力。

### 任务

- 实现 GIF incremental index/runtime fallback。
- 实现 rebuild 节流。
- 基准评估 native GIF cursor。
- 实现 iOS Flutter texture 或高效 image renderer。
- 实现 iOS lifecycle/device telemetry。
- 统一 Android/iOS conformance tests。

### 验收

- GIF current 页可边下载边展示可用快照。
- 屏外 GIF 不持续消耗 CPU。
- iOS 功能和 identity/session 语义与 Android 一致。

## Phase 11：发布硬化

### 目标

完成生产发布要求。

### 任务

- 故障注入和断电恢复。
- 长时间 soak test。
- 内存和 texture 泄漏检查。
- 隐私与日志脱敏检查。
- 可访问性和本地化。
- 发布性能基线和回归门槛。
- crash fallback 和用户可见错误体验。

### 验收

- 发布门槛全部满足。
- 无 P0/P1 已知问题。
- 模型完全关闭仍可稳定使用。

## 3. 首批 20 个实现任务

1. 初始化 monorepo 和 package graph。
2. 建立 `domain` ID 值对象。
3. 建立 ReaderObs。
4. 建立 fake monotonic clock。
5. 建立 deterministic priority scheduler。
6. 建立 DownloadSession 状态机。
7. 建立 writer lease。
8. 建立 Artifact partial writer。
9. 建立 append offset 校验测试。
10. 建立 partial → final promote。
11. 建立 SQLite cache schema。
12. 建立本地目录 ComicSource。
13. 建立 HTTP ComicSource fake server 测试。
14. 建立 RoleResolver。
15. 建立 HeuristicPolicy。
16. 建立 DemandPlan/DemandDiff。
17. 建立 Coordinator registry。
18. 建立静态 Reader vertical slice。
19. 建立 trace event schema。
20. 建立首个 100 页性能基准。

## 4. 推荐首个 Sprint 交付

第一个 Sprint 只做以下闭环：

```text
本地 manifest
  -> Reader PageView
  -> ReaderObs
  -> HeuristicPolicy
  -> DemandPlan
  -> fake Coordinator
  -> 静态页面显示
  -> trace 输出
```

不在第一个 Sprint 中实现：

- Rust WebP；
- texture；
- adaptive model；
- GIF；
- 复杂缓存 UI。

## 5. 代码审查门槛

任何资源相关 PR 必须回答：

1. identity 是什么？
2. 所有者是谁？
3. epoch 如何验证？
4. detach 后资源如何处理？
5. active claim 如何排空？
6. 是否在 UI isolate 执行重型工作？
7. 如何测试 stale result？
8. 如何观测性能变化？
9. 失败时如何回退？
10. 是否改变了 current 优先级？

## 6. 完成定义

任务完成需要：

- 实现；
- 单元测试；
- 必要集成测试；
- trace/metric；
- 文档更新；
- 无新增 analyzer warning；
- 性能敏感改动提供前后基准。


### Local-media 分层门禁

- App 页面不得实现目录递归、文件头 I/O 或 Android URI 访问。
- `packages/local_media` 拥有平台无关契约和桌面扫描。
- `packages/local_media_bridge` 拥有 Android SAF 与 resolver stream fallback。
- 修改 Flutter plugin 后必须通过 `./tool/clean.sh` 做干净构建。

## Android library vertical slice

1. Persist categories, comic preferences, custom order and chapter read state
   in the existing library store. **Implemented.**
2. Replace the demo-only home with Home/Bookshelf primary navigation while
   retaining diagnostic routes. **Implemented.**
3. Add animated cover cards and reusable download waterline presentation.
   **Implemented; 0.25.0-dev.29 binds the shared cover to authoritative persistent task snapshots.**
4. Add details preferences, chapter reverse order, read dimming and restore-
   unread swipe. **Implemented for grouped persisted chapters.**
5. Group local/remote chapter records into comic-level detail models.
   **Implemented for persisted chapter records.**
6. Bind per-chapter durable download commands to the comic-level projection.
   **Implemented in 0.23.0-dev.27; authoritative cover progress and cancel/retry/delete management
   are implemented in 0.25.0-dev.29.**


## Android library management and Reader controls slice

1. Remove Home directory-maintenance presentation while preserving import/source contracts.
   **Implemented.**
2. Reuse exact cover geometry across Home and Bookshelf; decouple view from sort mode.
   **Implemented.**
3. Add management selection, category insertion/move and isolated confirmed deletion.
   **Implemented.**
4. Add custom gallery long-press drag and list reordering. **Implemented.**
5. Add immersive Reader overlays, slider, animation controls, rotation, favorite and cache command.
   **Implemented; 0.23.0-dev.27 supplies the durable chapter-download callback.**
6. Add page-local pinch/double-tap zoom with PageView gesture arbitration and navigation reset.
   **Implemented.**
7. Move Reader chapter cache to durable storage. **Implemented in 0.23.0-dev.27; authoritative
   aggregate progress and download management are implemented in 0.25.0-dev.29.**


## Remote comic source browser slice

1. Add a third primary Comic Sources destination with a top management entry and bottom enabled-source
   switcher. **Implemented.**
2. Define catalog-owned browse/resource contracts and inject source implementations into App
   composition. **Implemented.**
3. Persist source enablement/order with a schema 2 to 3 migration. **Implemented.**
4. Implement one real remote source and map browse/detail/chapter manifests into the durable library
   plus existing Reader artifact ingress. **Implemented with MangaDex.**
5. Persist page identity independently of mutable remote delivery URLs and reconcile progress across
   refresh. **Implemented.**
6. Add source account/auth settings and update polling. Durable chapter offline state is implemented
   in 0.23.0-dev.27 and management/cancel/retry/delete UI in 0.25.0-dev.29; source update polling remains next.
7. Define Mihon/Venera repository metadata compatibility and the isolated host/session ABI before
   executable integration. **Metadata parsers and explicit host/session lifecycle are implemented in
   0.31.0-dev.38; shared trust/capability/quarantine/runtime-registry gates are implemented in
   0.31.0-dev.39; deterministic Reader transition replay is implemented in 0.31.0-dev.40; Android APK/Kotlin and JavaScript sandbox executors remain next.**

## Android remote-source reliability patch

1. Make generated Android Internet permission reproducible across bootstrap, run and release build.
   **Implemented in 0.21.1-dev.25.**
2. Preserve complete source URI/cause/stack details and expose selectable/copyable diagnostics.
   **Implemented.**
3. Bound connection wait and retry one transient MangaDex network failure without unbounded loops.
   **Implemented.**
4. Validate native platform HTTP adapters for proxy/VPN parity before changing the core streaming
   transport. **Next; no TLS or hostname bypass is permitted.**

## Superseded unified comic-details and refresh slice

1. Route source browse, Home updates, reading history and Bookshelf through one details component.
   **Implemented in 0.22.0-dev.26.**
2. Merge complete upstream manifests with persisted chapters by source-aware chapter identity.
   **Implemented; refresh never auto-imports a newly discovered chapter.**
3. Preserve persisted chapters that disappear temporarily from a successful source response.
   **Implemented as local-retained rows.**
4. Persist source authors/description/cover metadata with backward-compatible JSON decoding.
   **Implemented.**
5. Add pull-to-refresh while retaining source/store/Reader ownership boundaries.
   **Implemented for remote manifests and local-folder rescan.**
6. Add durable source update timestamps and update ingestion for the Home update rail.
   **Next.**


## Two detail owners, whole-comic shelf and source migration slice

1. Restore separate remote and local state owners while sharing stable details components and one exact
   route decision. **Implemented in 0.23.0-dev.27.**
2. Persist whole-comic metadata/catalog independently of chapters and migrate SQLite to schema 4.
   **Implemented.**
3. Make liked/shelf/collected/category actions whole-comic operations; make the chapter trailing action
   a durable download. **Implemented.**
4. Reuse complete persistent chapter artifacts in Reader after restart. **Implemented.**
5. Copy cross-source preferences and only exact chapter/progress/read matches after resolving target
   manifests; retain original source and bytes. **Implemented in 0.23.0-dev.27; schema 5 later removed
   the native-ID-only storage restriction.**
6. Migrate all legacy keys to source-composite schema 5. **Implemented in 0.24.0-dev.28 with
   compatibility decoding and auditable ambiguity reporting.**
7. Add download management/cancel/retry/delete and authoritative aggregate progress.
   **Implemented in 0.25.0-dev.29 using the existing DownloadSession/artifact authority.**
8. Surface auditable legacy migration issues with copy/export, pending/all filtering and explicit
   acknowledgement that never deletes the retained record. **Implemented in 0.26.0-dev.30 with schema 6.**
9. Add target-source side-by-side candidate comparison before migration. Search and manual-ID selection
   already exist; cover/author/chapter-sample comparison remains next.

## Cover management and download projection slice

1. Keep single-item delete and category migration on each management-mode cover; reserve the separate
   management surface for long-press multi-selection and batch operations. **Implemented in 0.27.0-dev.31.**
2. Preserve category migration and sort choices as bounded popup menus; use a separate custom-order drag
   handle so long press remains multi-select. **Implemented.**
3. Subscribe details and covers to authoritative chapter task state across route recreation. **Implemented.**
4. Distinguish single-chapter progress from whole-comic aggregate progress and clear the waterline at
   terminal completion. **Implemented.**
5. Add whole-comic download while retaining per-chapter DownloadSession/artifact ownership and cancellation.
   **Implemented.**
6. Remove cover metadata rows, overlay title, keep reading progress in details, and coalesce rapid route taps.
   **Implemented.**
7. Add durable queue scheduling, concurrency limits, pause/resume and network/power policy for whole-comic downloads. **Implemented in 0.28.0-dev.32.**
8. Add side-by-side target-source migration candidate comparison before confirmation. **Next.**

- 首页持久封面索引由 storage-owned compact manifest 一次加载；逐项 JSON 仅用于 crash recovery/migration。启动 trace 必须区分 bootstrap、service open、cover source origin 和 first frame，不得反向控制加载策略。

### dev.69 历史约束（由 dev.70 替代）

#### dev.69 当时的优先级

- Venera 普通图片正文不得通过 JSON/Base64 或 JavaScript typed-array 返还宿主；来源确实需要 `onResponse`/`modifyImage` 时才允许进入兼容路径。
- 每个 runtime invocation 的 bridge HTTP 必须携带 requestId；取消和 demand detach 必须终止对应 native connection，而不只是忽略迟到结果。
- Venera Reader 默认只请求当前页且 runtime 串行。扩大并发或预取前必须有设备 trace 证明不会重复执行 `onImageLoad` 或上传请求体。
- Pipeline 输入产生相同 role window 时不得递增 revision 或重新提交同一 demand plan。
- 连续布局的媒体尺寸、viewport 和拼接设置变化必须保持当前可视锚点；用户拖动时禁止任何自动 `jumpTo`。拼接设置是继承/启用/停用三态。
- 懒列表测试必须先让目标 child 进入构建范围，再读取 Widget/RenderObject；禁止对未满足 finder 数量的结果使用 `.single` 或 `tester.widget`。

### dev.68 当前主线约束

#### dev.68 当前优先级

- locator 兼容性是 Reader/下载入口不变量，不是详情页刷新选项；任何 generation-scoped Venera token 都必须在创建 page demand 前刷新或失败。
- 插件资源边界必须在 runtime invocation 前拒绝已知不可恢复 identity；禁止依赖失败后的 pipeline 重试来发现旧 token。
- deferred plugin resource 的预取窗口和重试次数必须显式受限。扩大窗口或恢复自动重试前需以 trace 证明收益，并分别核算配置解析、HTTP 请求和页面字节流量。
- 纵向拼接必须从 render tree 中移除 separator，而不是把 separator 高度设置为零；拼接媒体须使用统一的宽度贴合策略，避免 `contain` 的舍入边缘重新露出背景。加载占位可调整布局，但不得裁切或拉伸漫画页。

### dev.67 当前主线约束

#### dev.67 当前优先级

- Reader 页面导航只有一个 Presentation 所有者：底部 Slider 与直接手势。顶部栏、本地媒体适配器和来源详情不得再次实现页码、上一页/下一页或选页菜单。
- Reader 布局选择只有设置所有者：全局阅读设置与按 `sourceId + comicId` 的每漫画覆盖。顶部快捷布局菜单不得恢复。
- Reader runtime 的调用方只能提供领域数据或窄化的只读字符串投影，不能注入任意 action Widget、持有 `ReaderController` 或创建第二套导航状态。
- Reader 组合、会话设置模型和自适应分类必须保持文件级分离；`reader_runtime_screen.dart` 上限为 1500 行。
- 连续列表命令只有在目标页面完成布局并由 observation 确认后才能 acknowledge；测试必须等待语义条件，不能依赖固定 pump 次数。

### dev.66 当前主线约束

#### dev.66 当前优先级

- Venera 页面 locator 必须跨 runtime generation 可恢复；持久化 legacy token 必须刷新，禁止让 pipeline 对确定性失效 locator 无限重复请求。
- 并发合并只用于同一逻辑资源的进行中工作；完成后的页面字节继续由 session/artifact/cache 既有所有者持有。
- 连续布局优先使用来源尺寸，其次使用同一媒体载荷解析出的尺寸。禁止为测量再创建第二条 ImageStream，禁止通过裁切掩盖错误比例。
- Reader 控制命令必须在目标滚动容器完成 attach/layout 后才 acknowledge；布局切换不得让页码、前后翻页或 slider 进入假成功状态。

- Venera 新章节资源 locator 必须跨 runtime generation 可恢复，并只编码宿主批准的版本化 image/comic/episode identity。不得把任意 URL、header、脚本或网络配置作为可伪造 locator 载荷。legacy runtime token 只作读取兼容。
- 每漫画设置是 `sourceId + comicId` 的小型 Presentation preference，仅可覆盖 Reader 方向、纵向拼接和自适应开关；不得包含 artifact、下载、缓存、Cookie、插件 session 或 pipeline demand。
- 自适应布局只选择 Reader presentation mode。输入限于来源/进度方向、页面几何和动画 hint；低置信度回退既有值，hint 不能替代字节嗅探。
- 纵向连续列表必须保持每页稳定 asset identity。拼接只控制视觉间距，不能把相邻图片合成一个文件、缓存项或 decode identity。
- RTL Reader 的 slider 最小/最大方向和端点标签必须镜像；页面 index、持久进度和 DownloadId 不反转。
- Debug trace producer 可在 build 期间记录，但观察通知必须合并到安全帧边界。

### dev.63 当前主线约束

- `ImportedPageRecord.pageId` 是页面唯一 identity；资源 URI 是可变、可重复的 delivery locator。任何 catalog/download/cache 层都不得用 URI 重复拒绝合法章节。
- 插件私有页面资源必须由 `downloads` 通过注入的 source loader 选择 transport；Presentation 只能请求下载或打开，不能识别 URI scheme 后自行联网或保存字节。
- Venera/Mihon 的 `contentKindHint`/`animatedHint` 是加速提示，不能替代字节嗅探和 codec 校验；未知 token 不得被猜成 WebP。
- 历史上 Mihon `pageCount == 0` 曾由详情页渐进 preflight；该方案已由 dev.78 / ADR 0062 否决。普通章节保持待加载，详情页不得为标签请求正文；synthetic gallery 的非空验证例外保留。
- synthetic gallery 可在目录路径全部为空或失败后尝试，但必须以真实非空 page list 为准；若 page preflight 失败，目录错误必须保留在诊断链中。
- Venera HTTP redirect 由宿主逐跳管理，必须有限、逐跳保存 Cookie、解析相对地址并在跨 origin 时移除 Cookie/Authorization；底层 URLConnection/OkHttp 不得再次自动跟随。
- Reader transfer notifier 不得在 build phase 同步发布；同一帧的 snapshot 变化应合并为最新值并在安全帧边界更新。

### dev.62 历史约束（由 dev.63 保留并扩展）

- 漫画源管理负责启用来源的原生/Mihon/Venera 分类；Mihon 多语言来源折叠只发生在该投影。
- Mihon/Venera 安装页只能通过顶部“已安装/仓库”切换，不得恢复左右双栏或在生态内部重复分类。
- 设备 Mihon 扩展扫描属于 Mihon 已安装页，拥有独立 refresh/busy/error 状态；仓库加载不得禁用或覆盖设备扫描。
- Mihon synthetic chapter 是经过非空 page-list preflight 的 gallery adapter，不得用于吞掉 reactive 解包、目录网络或反射错误。
- remote chapter `pageCount == 0` 表示目录阶段未知；UI 必须显示待加载，读取后以真实 manifest 页数替换。

### dev.61 历史约束（已由 dev.62 替代）

- `apps/app` 只装配顶层页面和业务服务，不直接拥有 Reader session/transport/media pipeline。
- `reader_runtime` 是 Reader composition 唯一入口；`local_media_ui` 是本地图片/WebP presentation 唯一入口。
- `webp_demo.dart` 与 `reader_runtime.dart` 保持薄 facade，不允许重新堆实现。
- Mihon/Venera 安装列表只出现在各自生态页面左栏；仓库/设备发现只在右栏。
- Mihon 多语言折叠只改变展示，不改变插件 identity、安装、更新或 trust 粒度。

### dev.60 当前主线约束

- Mihon 单章节是最终空目录兜底，不是组合详情缺字段时的默认答案；目录探测必须跨候选对象与兼容 API 完成。
- Venera 登录是隔离来源能力：Flutter 负责输入与 WebView 用户交互，runtime 负责校验回调、Cookie/localStorage 写入和登录状态持久化。
- durable 书架恢复不得阻塞首个可操作 Home surface；后台恢复状态只能以非模态提示呈现。
- Reader 手势由当前缩放状态裁决：scale=1 由 PageView 翻页，scale>1 才由页内缩放/拖动接管。
- 静态媒体不暴露动画播放控制；远程 WebP 必须复用权威 DownloadSession 的增量 source，并分别呈现恢复前缀与本次传输进度。
