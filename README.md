`0.31.0-dev.86` 严格以 dev.85 交付 ZIP 为唯一基线，修复详情页新增 WebView callback 漏提交 `ComicDetailsSourceWebViewOpener` typedef 导致的四处 Dart 编译阻断，并把通用 Android 网络能力从 `plugin_host_bridge` 拆到独立 `network_bridge`。`network_bridge` 现在拥有通用来源 WebView、Cookie/localStorage 快照、Android CookieJar、Cloudflare challenge interceptor 与 fallback DNS；App composition 直接注入该 facade，`ExternalPluginController` 不再转发通用网络命令。Mihon `NetworkHelper` 仅保留 ABI 适配，Venera/Mihon 插件调用、信任和隔离生命周期仍由 `plugin_host_bridge` 拥有。共享网络类作为 Android library 暴露并被 Mihon classloader parent-first 使用，release shrinker 规则和运行时完整性检查同步补齐。浏览器进程由 App manifest placeholder 组合，快照以同目录临时文件原子替换跨进程交接，不再依赖跨进程不可靠的 SharedPreferences。未引入 rhttp；未来 rhttp 或其他原生网络后端必须作为共享 transport/network composition 注入，不能回到插件桥私有实现。dev.85 的章节失败、256 KiB 分块、本地文件/SAF 流式读取和 Reader Pipeline 策略保持不变。

`0.31.0-dev.85` 严格以用户本次上传的 dev.84 为唯一基线并先覆盖 staged 文件，修复 Mihon/JMComic Cloudflare 章节目录失败被伪造成“正文”单章节的问题。章节调用异常现在作为权威错误冒泡；仅在章节目录能力确实不存在且 gallery 页面预检非空时才允许 synthetic 兼容。详情失败态提供稳定 WebView 图标和重试入口，旧 synthetic 章节只在 App composition 通过 `plugin_host` 明确 helper 与已恢复的权威目录协调淘汰，Presentation 不解析插件 token。默认数据传输块提升为 256 KiB，64 KiB source/Trace 聚合量子保持不变；普通本地文件由 `FileTransport/RandomAccessFile` 直接分块，Android `content://` 改为可取消的 open/readChunk/close 流式句柄并支持 range/validator 回退，不再把整张大图作为单个 MethodChannel 对象复制后才进入既有 DownloadSession/Pipeline。Reader 7/3、2/1、current/transition 与 5/3/2 未改变。

`0.31.0-dev.84` 以 dev.83 为唯一基线，修复 Mihon/JMComic 静态正文转译、组合章节目录和详情元数据。宿主不再假设所有 Mihon 图片只靠 URL/headers 即可直连：普通来源继续流式 transport，拥有扩展自定义 interceptor/cookie/auth/DNS 能力的来源由隔离 runtime 执行 source client 转译，再进入同一 DownloadSession/Pipeline；其 chapter source revision 带 transport 版本，避免继续命中 dev.81–83 已缓存的未转译正文。`SMangaUpdate.chapters` 非空时直接采用，不再重复调用章节接口。Mihon source 名称、description 与 genres/tags 完成 domain/catalog 持久化和详情投影；已持久化章节页数会按 chapter token 或唯一 source revision 回填章节行。“下载整本”与三个偏好图标统一，“继续”使用药丸，tags 一行折叠并可点击展开。

`0.31.0-dev.83` 以 dev.82 为唯一代码基线，恢复被 source scheme 分支破坏的稳定预下载：Mihon、Venera、HTTP、本地和恢复 artifact 全部使用前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传与 5/3/2 lane。每漫画自适应迁移 VibeVenera 的 model v4 可移植逻辑，以 title/tag/category/language/显式 source type、两份非封面页面几何或两份实际解码动画为证据，几何评分同时使用相同 tag weight/softmax，并将带 metadata fingerprint 的 profile 持久化到漫画设置；普通来源方向、manifest `animatedHint` 和 `.webp` 后缀均不再冒充实际自适应证据。连续拼接的页面高度按 DPR 对齐到同一物理像素网格，stitched texture 直接填充 Reader 权威 page box，普通滚动不再在每个边界叠加独立 FittedBox、ClipRect 与 RepaintBoundary。未通过 overlap、负位移、遮罩、缩小窗口或降低并发隐藏问题。

`0.31.0-dev.82` 以 dev.81 为唯一代码基线，按设备截图、完整 20000 条 Trace 与真实 Flutter 失败修复三项同源退化。动画 WebP 的 blend/dispose 现在先在源像素网格完成完整 canvas 合成，再将整帧一次性等比缩放到统一 8 像素对齐目标，禁止分别缩放每个 ANMF 子矩形造成水平条带错位。动画推进不再依赖 source revision：当前输出帧被播放计时器消费后，`LiveCoordinator` 会独立补充 decode watermark；source 小块增长只按 64 KiB 边界、seal 或 failure 唤醒等待数据的 decoder，且只有真实 holder/output 变化才触发 upload。`DownloadSession` 同样按 64 KiB 聚合 `bytesCommitted` telemetry，raw Trace 默认上限降为 10000 条，保留原始顺序及 dropped/aggregated 计数。三个 transport 测试修复暂停订阅与 controller close 的确定性死锁，纵向几何使用数值容差而非 double 精确相等。下载 +7/-3、预解码 +2/-1、current/transition 上传与 5/3/2 lane 未改变。

`0.31.0-dev.81` 以 dev.80 为唯一代码基线，按设备 Trace 与真实 Flutter 失败重新关闭三条产品链和一组测试退化。Mihon 普通图片不再由插件 runtime 完整下载后作为单个二进制响应返回；插件只解析最终 URL、headers 与 GET request plan，宿主 `ExternalPluginResourceTransportPool` 直接按 chunk 写入既有 `DownloadSession/artifact/ingress`，只有直连失败后才使用 source-owned 完整字节兼容回退。`DownloadSession` 持有单次网络 run 的 partial 基线，未知 Content-Length 在首个新增 chunk 后投影 receiving。`UploadSession` 等待异步上传排空后再退休平台 slot，旧 revision 的成功或失败均不能污染新 demand，修复动画播放数帧后 texture failure 停滞。章节点击先同步 push 黑色 Reader route，再在 route 内解析 chapter、检查离线 artifact 与组合 loader。普通图片和 WebP 均由统一 viewport 居中；下载 +7/-3、预解码 +2/-1、current/transition 上传与 5/3/2 lane 未修改。真实 socket、固定超时、`pumpAndSettle`、lazy child 数量、魔法像素阈值和由静态门禁强制的 400ms 等待均已删除；测试改为可控 Stream/Future、注入的单调时钟与 Reader owner 的纯几何验证。

`0.31.0-dev.80` 以 dev.79 为唯一代码基线，修复原子媒体链仍遗漏的增量调度、统一缩放和 Android 诊断导出。encoded source 的每次增长、seal 与失败都有单调 revision；Decode lane 会排空任务活跃期间到达的新 revision，同 key 后续任务不会重复消费最新 revision。普通图片、完整动画和 Pipeline WebP 统一使用 `AlignedRasterSize` 的 contain、原比例和 8 像素物理栅格契约，`MediaAspectViewport` 是唯一 fit 决策，尺寸未知时也不会使用 `BoxFit.fill`。Android Trace 文件保存改用 App-owned SAF `CreateDocument` 通道，复制是独立的 64 KiB 有界 UTF-8 投影。未知 Content-Length 仍不伪造百分比，但 committed bytes 增长会明确投影为 receiving。下载 +7/-3、预解码 +2/-1、current/transition 上传和 5/3/2 lane 未修改。

`0.31.0-dev.79` 以 dev.78 为唯一代码基线，停止继续叠加媒体抽象，集中恢复插件、封面和 Reader 的既有稳定行为。Venera JavaScript source operation 现在由 `plugin_host` 单 in-flight 调用，WebView 不再保留第二套 raw `loadInfo` 对象缓存；Mihon 隔离运行时仍使用配置并发。所有 source-owned absolute locator（包括 `mihon:resource:`）统一经 `ComicSourceResourceGateway -> ResourceCacheManager`，完整 encoded-image resolution 按稳定 key 合并。DownloadSession 在 source 创建、每次增长、seal 和失败时通知同一 Decode demand；恢复的 ready source 会立即投影，Decode/Upload 将权威失败显示为错误而不是永久 loading。连续阅读未知高度使用与 current page 无关的稳定 extent，并只在 idle 时按顶部像素锚点补偿真实尺寸；运行时确认 Animated WebP 时，自适应布局优先切换到分页方向，除非用户存在显式漫画级方向覆盖。下载 +7/-3、预解码 +2/-1、current/transition 上传和 5/3/2 lane 均未修改。

`0.31.0-dev.78` 以 dev.77 为唯一代码基线，修复原子媒体迁移后的输出几何、需求重入、章节入口竞争和诊断导出闭包。WebP decode 尺寸现在是最大边界：源 canvas 在边界内等比 fit，不再按 viewport 宽高独立拉伸；上传/texture 使用实际 frame 尺寸。静态或有限动画页面在移出窗口、holder 已空后重新进入会由 Pipeline 重建 cursor，不永久保留帧也不把 EOF 改成无限循环。详情页不再为页数标签加载所有章节正文，已读持久化不阻塞路由。Debug Trace 保留小型合并 UI 投影，同时新增较大的有界 raw export ring，复制和 JSONL 导出使用原始事件并报告保存错误。下载、预解码、上传窗口与 5/3/2 lane 均未修改。

# zic

`0.31.0-dev.77` 以 dev.76 为唯一基线，原子收回 Reader WebP 的 source、cursor、decode、upload、动画推进与 texture 生命周期。App 只注入一个 `PipelineMediaRuntimeFactory`，`pipeline_runtime` 创建并关闭 session-owned runtime；Presentation 只消费 `PipelinePageOutputStream` 与 opaque `PipelinePageSurface`，不再取得 `EncodedSource`、textureId 或 native handle。Android texture 按稳定 `DecodeId` 复用，并在最后一个 output claim 释放后退休；surface replacement 会先完成下一帧视觉切换再释放旧 claim。播放配置由 UploadRegistry 原子保存，用户暂停与 viewport freeze 分离，避免异步 present 或解除暂停误唤醒 transition 页；playback ticker 仅在存在 running timer 时运行，静态页和冻结页不再空转。下载 +7/-3、预解码 +2/-1、current/transition 上传与 5/3/2 lane 未改。

`0.31.0-dev.76` 以 dev.75 为唯一基线，修复纵向拼接的双加载圈：Reader 删除 viewport 固定居中 overlay 与页面 ready 集合，页面媒体成为唯一可见 loading/ready/invalid 所有者，首帧回调仅保留 telemetry。设备 trace 显示立即退出时 7 个 demand 均完成 detach，未见异常、退出后继续收包或生命周期泄漏；Pipeline 的前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传和 5/3/2 lane 未改。

`0.31.0-dev.75` 完成 dev.74 后续编译闭包并收紧契约归属：删除无生产调用的详情兼容包装和 AssetBundleTransport 转出 facade，底层 transport 测试迁回 `pipeline_runtime`，下载 identity 测试留在 `downloads`，并新增可直接复制的 Architecture/耦合迭代提示词。媒体策略与 dev.74 保持不变。

后续新聊天可直接使用 [`docs/AI_ITERATION_PROMPT.md`](docs/AI_ITERATION_PROMPT.md) 中的执行提示词。

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader、可恢复下载、
持久化缓存恢复、容量/LRU 策略、受控清理、失败退避重试、独立资源 lane、格式感知 ingress、
decode/upload registry、frame holder、viewport 播放门控、帧字节预算、可运行的 Animated WebP App 入口、viewport/DPR 自适应显示目标、source-aware 解码 raster、Rust 增量 Animated WebP 解码基础，以及按 `sourceId + comicId` 聚合多章节的 Android Home/Bookshelf/详情闭环。`0.20.0-dev.23` 统一首页与书架封面、补齐分类与管理操作、自定义画廊拖动，并为 Reader 增加沉浸控制与缩放。`0.21.0-dev.24` 新增第三个漫画源页面、持久化源管理、底部源切换和首个可浏览的 MangaDex 远程源；远程章节继续进入现有目录库与 Reader artifact 管线。`0.21.1-dev.25` 修复生成 Android host 的发布联网权限，补充可选择/复制的完整漫画源错误诊断、连接超时和有界瞬时重试。`0.22.0-dev.26` 验证了来源感知目录合并和下拉更新；`0.23.0-dev.27` 将状态所有权收敛为远程/本地两套详情页、共享稳定组件与集中路由，并补充整部漫画收藏/入架、章节持久下载及保守的跨源迁移。 `0.24.0-dev.28` 将章节、进度、漫画偏好和已读状态统一迁移到 `sourceId + nativeId` 持久身份，允许不同漫画源安全复用相同原生 ID，并记录旧数据的歧义迁移。`0.25.0-dev.29` 在既有 DownloadSession/artifact 管线上增加权威任务快照、下载管理、取消/重试/删除、页数与字节进度，以及首页/书架共享封面的下载水位投影。 `0.26.0-dev.30` 增加可复制和显式确认的书架迁移诊断，将旧库歧义记录保留在 schema 6 中，并收敛 Reader 控制、章节打开/下载竞争、书架排序/移动和下拉更新交互。 `0.27.0-dev.31` 将单项管理操作恢复到封面、以长按进入批量选择，区分单章与整本下载投影，并加入整本漫画下载、跨页面权威任务状态和防重复封面导航。 `0.28.0-dev.32` 将整本下载提升为可恢复的持久队列，支持全局并发、暂停/继续、取消/重试以及 Android 非计费网络和充电策略门，并修复书架排序编译阻断与小屏 Reader 倍速选择。 `0.28.1-dev.33` 修复下载管理章节列表的无限循环/OOM、整本队列关闭顺序，并收敛相关 Widget 测试的有界等待与卸载。 `0.29.0-dev.34` 在跨源迁移写入前增加来源/目标作品并排核对，展示封面、作者、原生身份、章节样本和明确风险，并要求用户确认目标身份。

`0.31.0-dev.72` 以 dev.71 为唯一基线，将 Reader 的下载、解码、上传、artifact、进度与会话生命周期彻底迁入独立 `pipeline_runtime` 所有者。Reader 只提交 `ReaderObs` 并消费只读 `PipelinePageStream`；当前页传输进度也由 Pipeline 从 observation 内部选择，不再由 Reader 单独指挥。首页、来源浏览和详情页封面统一经 `ComicSourceResourceGateway -> ExternalPluginResourceTransportPool -> ResourceCacheManager`，Venera HTTP 封面优先使用 `onThumbnailLoad`，章节 locator 使用 `onImageLoad`，同 locator 的 request plan 在宿主与运行时两层有界复用。普通图片正文继续使用 dev.70 的共享流式 transport，前 7/后 3 下载、前 2/后 1 预解码与 5/3/2 lane 保持不变；本轮没有通过关闭预取或降低并发掩盖流量问题。

`0.31.0-dev.71` 以 dev.70 为唯一基线，修复来源资源能力接口的静态类型编译错误，并将 complete-byte fallback 与 streaming transport 收敛为一次性 `ChapterResourceAccess` 绑定。App 新增独立 `ComicSourceResourceGateway`，统一 source lookup、旧 Venera locator 拒绝、transport pool 生命周期、Reader response loader 与章节下载组合；Home 不再直接持有来源 transport pool 或分两次设置下载服务。gateway 关闭会先解绑外部下载服务，防止遗留指向已关闭组合对象的回调。

`0.31.0-dev.70` 以 dev.69 为唯一基线，直接参考用户上传的 VibeVenera 流式图片管线：Venera 插件只解析受限的图片请求方案，普通图片正文由共享 host transport 按 chunk 写入既有 DownloadSession/artifact/ingress。恢复稳定的前 7/后 3 下载预取、前 2/后 1 预解码与 5/3/2 独立 lane，JavaScript 配置解析保持串行。章节下载和 Reader 进度改为 authoritative session 投影，首 chunk 后显示真实字节进度，promoted/restore 页面不再闪烁；GET/HEAD 不上传 body，trace 只保留 Venera token 的 hash 与长度摘要。

`0.31.0-dev.69` 对 dev.65–68 的 Venera/连续 Reader 回归做了差异审计并替换无效补丁：普通 Venera 图片正文不再作为 Base64 数组往返 WebView JavaScript，而由受限原生 HTTP 返回一次性二进制 token；GET/HEAD 强制无请求体、Venera 调用串行且只请求当前页，页面/demand 取消会断开对应原生连接，未变化的 pipeline role window 不再重复提交同一计划。纵向拼接将旧每漫画 `false` 迁移为“继承全局”，拼接树无 separator 并覆盖物理像素接缝；媒体尺寸与 viewport 变化按视口锚点重排，不在拖动期间回跳，加载指示当时由 Reader viewport 单一居中所有；该决定已被 dev.76 / ADR 0060 的页面媒体所有权取代。长期失败的纵向 Widget 测试已修改到原先直接读取未构建 lazy separator 的具体断言。

`0.31.0-dev.68` 将 Venera 兼容检查提升为 Reader/下载入口硬前置条件，但仍保留大图 JavaScript/Base64 传输、取消不终止原生连接、重复 role-window 提交和连续布局回跳等缺口；这些部分由 dev.69 替代。

`0.30.0-dev.35` 完成了 Home/Bookshelf 的第一阶段 Presentation 拆分，但其中新增的 App 内封面缓存和 Reader 页面字节预热违反了既有资源所有权。`0.31.0-dev.36` 正式替代该设计：`ResourceCacheCoordinator` 只协调两个已有所有者，而不建立第三套媒体缓存。`resource_cache` 管理封面/来源图片响应、漫画详情、章节元数据和搜索结果的 TTL、全局/分类型预算、并发合并、LRU 与来源复合失效；章节页面仍以独立 partial/final artifact 进入 `ReaderBinding -> PipelineController -> DemandPlan -> LiveCoordinator -> DownloadSession`，解码帧和纹理继续由 session/media/renderer 持有。`catalog` 提供缓存装饰器与图片资源适配，`downloads` 持有页面 artifact 下载和整本队列，`downloads_bridge` 只做平台信号及持久化适配，App 仅装配接口和呈现状态。`0.31.0-dev.37` 在页面
`promoted` 后将 Reader 临时 artifact 提交到持久层；`0.31.0-dev.38` 进一步持久化完整封面响应、保持翻页
中点前后稳定的媒体 Widget identity，并建立 Mihon/Venera 仓库元数据与隔离执行 host 的兼容边界。

`0.31.0-dev.43` 在该文件型路径上继续收敛启动 I/O：持久封面以一次加载的 compact manifest 建立 warm-hit 索引，逐项 JSON 仅保留为崩溃恢复日志；Home 记录 bootstrap、服务打开、封面来源与首帧的同一时间线。Android Mihon bridge 已通过后台 `PackageManager` 读取未安装 APK 的包名、当前签名、版本和 extension ABI，Venera inspector 则从同一份有界字节快照完成 UTF-8 metadata 与 SHA-256 检查，仍不执行插件代码。
`0.31.0-dev.44` 保留该 Home trace，但不为当前未复现的冷启动问题增加额外工作；资源文件缓存改用显式复合能力，WebP ready 收敛到真实首帧，promoted artifact 在权威 session 排队时启动唯一共享读取。Mihon inspection 进一步读取入口类元数据，Mihon 与 Venera 分别获得不可变 payload 和资源上限执行请求契约，具体 class loader/JavaScript 引擎仍必须位于隔离 adapter。
`0.31.0-dev.45` 修复插件资源上限值对象的 const 求值阻断，并定义 Mihon/Venera 共用的版本化运行时协议。隔离 backend 只暴露 source descriptor 与 browse/detail/chapter/resource 请求，统一适配层再生成普通 `BrowsableComicSource`；请求超时、响应字节和真实并发由 host 二次约束，Reader、下载会话和 artifact 权限不会跨入插件运行时。
`0.31.0-dev.48` 收口了重复出现的图片测试进程阻塞：普通本地文件的 zero-Dart-copy 验证改为纯 `FileImage` 路由测试，不再启动平台解码；受控动画状态机通过 `FlutterAnimatedCodecFactory` 与 `ui.Codec` 适配器解耦，生产仍使用真实 Flutter codec，测试使用确定性 codec。首帧 ready 等待真实 `endOfFrame`，失败路径也会无条件卸载 codec、Timer 和图片。Home trace 与 dev.47 的 Mihon/Venera runtime worker、取消和平台通道保持不变。
`0.31.0-dev.49` 修正了目标重建回归的错误前提：2×2 源在 320→180 视口下不需要重建 codec，测试改用声明 2048×2048 画布的确定性 VP8X fixture，并先验证两个 downsample target 确实不同。插件隔离边界新增 process-entry activation host：原始 payload 在隔离进程内按批准的长度/SHA-256 流式重验并原子复制到进程私有文件，driver 只接收该已验证副本；session registry 不在进程重启后自动重放失败请求。
`0.31.0-dev.50` 修复 process runtime 的编译闭环，并把 Android 专用服务的协议入口收敛到 Dart `ExternalPluginRuntimeServiceEndpoint`：平台只转发原始 method/wire message，payload staging、session registry、取消和关闭仍由共享 process host 持有。每次激活返回新的 `processId`，旧服务进程的 invoke/cancel/close 在 session ID 查找前即被拒绝，不会自动重激活或重放。
`0.31.0-dev.51` 补齐 Android 专用 runtime service 的实际启动与跨进程传输：非导出 Service 在 `:zic_plugin_runtime` 进程创建不自动注册插件的 FlutterEngine，执行保留的第二 Dart 入口并挂接同一 service endpoint。主进程通过一次性 correlation request 绑定服务；服务死亡只失败当前请求，不重放。小消息以内联 Binder envelope 传递，大型二进制响应通过应用私有原子 packet 文件回传，避免 base64 与 Binder transaction 上限。服务目前仍没有 Mihon/Venera driver，因此 activation 在专用进程内明确 fail-closed。
`0.31.0-dev.52` 进一步关闭真实 service-death 和大响应完整性边界：每次显式绑定拥有独立 generation，并通过 Binder death recipient 观察进程死亡；旧回调不能拆除后来建立的连接，绑定阶段超时也不会永久阻塞下一次显式 activation。packet 文件现在携带 SHA-256，host 在一次读取中同时验证 canonical root、长度和摘要，消费或校验失败后均删除文件。Home trace 与媒体/Reader 所有权保持不变。
`0.31.0-dev.53` 在该边界内接通真实 Mihon/Venera 运行时和漫画源管理入口：Mihon 从已验证 APK 副本发现并调用 1.6/旧版 Source API，并解析当前仓库 `extensionList.extensions` v2 索引；Venera 在受限 WebView 中实现 1.6 网络、Cookie、存储、转换、HTML、数组/对象/`Map` 数据形态与图像处理桥。安装、信任、更新、回滚、移除和重启恢复统一由 plugin host 管理，外部源仍只以普通 `BrowsableComicSource` 进入现有缓存、下载与 Reader 管线。
`0.31.0-dev.54` 修复外部插件 manifest 恢复的 Dart 编译阻断，并把 JitPack 配置提升到真正解析 App runtime classpath 的生成宿主仓库所有者；Groovy/Kotlin DSL 与旧 `www.jitpack.io` 地址均被幂等归一化。Mihon extraction 改为 activation 独立 workspace，请求关闭在真实任务排空后再释放 source 和代码缓存，专用 Service 启动时清理上次进程死亡遗留目录。
`0.31.0-dev.56` 在 dev.55 单一 Mihon ABI 基础上补齐真实运行环境：APK 使用 payload 专属 Context/资源/隔离存储并兼容 object、工厂和构造器入口；Venera 归一化当前 explore/category 契约、压缩协商，并对公共域名被异常解析到回环地址提供受限且保持 TLS hostname 的 DNS 回退。
`0.31.0-dev.57` 关闭真机反馈中的一组运行时缺口：Mihon APK 在 dex 加载前以同目录原子流程提升为只读文件；Venera 同时兼容 `load/loadNext`、直接 HTTP(S) 封面资源、方向别名和类级 source key，且响应头适配同时接受 Android nullable 与 OkHttp non-null multimap。
`0.31.0-dev.61` 继续以 dev.60 为唯一基线：Reader 会话装配已从 App Presentation 迁入 `packages/reader_runtime`，本地图片/WebP UI 迁入并拆分到 `packages/local_media_ui`，修复 `SourcePool` 与 WebP 前缀探测符号遗漏，同时降低 App 对 pipeline/session/storage/transport 的直接耦合。dev.61 曾尝试双栏插件管理与仓库语言折叠；该信息架构已由 dev.62 明确替代。
`0.31.0-dev.62` 修正外部插件信息架构：漫画源管理中的启用来源按原生、Mihon、Venera 分区，Mihon 语言变体在这里折叠；Mihon/Venera 独立页面改为顶部“已安装/仓库”页签，设备扩展扫描归属 Mihon 已安装页。Mihon runtime 同时修复 reactive 返回值解包、空结果吞错和 synthetic gallery 0 页问题；未知远程页数显示为待加载。
`0.31.0-dev.63` 收口插件媒体兼容链路：Venera/Mihon 页面携带 WebP/动画提示并仍由字节嗅探最终裁决；插件私有资源 URI 通过 `downloads` 注入式 source transport 进入持久下载；Mihon 未知页数当时在详情页受控预检后渐进更新（该普通章节预检已由 dev.78 / ADR 0062 撤销），空目录但可读取正文的 gallery 允许经真实页面预检生成单章；重复图片 URL 不再冒充页面身份。Venera 网络桥改为逐跳 Cookie 的有限手动重定向。
`0.31.0-dev.64` 修复 dev.63 的两个 Dart 编译阻断，并新增第四根导航“杂项”、分层设置、可执行数据备份/缓存维护与有界 Debug trace；偏好持久化通过 `storage_bridge` 注入，设置页不取得 Reader、下载、缓存或插件资源所有权。
`0.31.0-dev.65` 修复 Mihon Android bridge 的 `Locale` 导入，并把 Venera 章节页从运行时内存 token 改为受约束、可持久恢复的自描述资源定位符；Reader 新增全局与每漫画方向/自适应/纵向拼接设置，纵向模式使用按页面比例的连续列表，RTL 页码滑杆与分页方向一致。Debug trace 通知改为帧后合并，避免观察面板在 Reader build 中触发重建。

```text
ReaderView
  -> ReaderObs
  -> ReaderBinding
       -> ViewportResolver / playback gate
  -> HeuristicPolicy
  -> DemandPlan
  -> LiveCoordinator
       -> NetLane
       -> DecodeLane
       -> UploadLane
       -> DownloadRegistry / DownloadJob / DownloadSession
            -> Ingress / SourcePool
       -> DecodeRegistry / DecodeSession / FrameHolder
       -> UploadRegistry / UploadSession / OutputFrame
       -> FrameBudgeter (current reserve)

CacheIndex
  -> CachePolicy (LRU candidate selection)
  -> CacheOps (session-safe trim / clear)

media
  -> content sniff -> WebP-only source allocation
  -> artifact rebuild -> encoded source

Rust media_core
  -> source create / append / seal / reset
  -> epoch + contiguous offset + memory budget
  -> libwebp partial demux
  -> complete-frame decode + blend/dispose composition
  -> retained immutable RGBA frame handles
  -> frame/play-count metadata + explicit cursor rewind
```

## App 演示入口

App 不再启动后直接进入静态章节。首页提供五个明确入口：

```text
100 页静态章节
Reader 媒体管线
内置动图 WebP
导入本地 WebP
导入图片文件夹
```

内置动图来自 `native/media_core/testdata/` 的真实 decoder fixtures，并同步到：

```text
apps/app/assets/demo/animated/
  animated.webp
  finite_loop.webp
  partial_blend.webp
  index.json
```

运行：

```bash
cd apps/app
flutter run -d android
```

## 漫画源

主导航第三页为漫画源浏览，首次进入时才创建远程浏览页。顶部入口管理源的启用状态与顺序，页面底部在已启用源之间切换。当前内置 `MangaDexSource`，支持分页发现、标题搜索、详情和章节列表。源层只产生 catalog manifest，不创建 Reader、DownloadSession 或数据库。

详情采用两套状态所有者和一套共享呈现组件：未持久化的 `sourceId + comicId` 进入 `RemoteComicDetailsScreen`；整部漫画已经收藏、加入书架、喜欢，或已有持久章节时，同一源入口集中路由到 `LocalComicDetailsScreen`。两页复用封面/元数据头部、整部漫画偏好、分类、章节行、错误面板和下拉更新，但不会让远程瞬时目录与本地持久状态竞争同一个 Widget 生命周期。

`SavedComicRecord` 独立保存整部漫画元数据和轻量章节目录，因此加入书架或收藏不再隐式导入任意章节。章节点击负责阅读；章节行尾部的主要持久操作是下载。远程章节在阅读或下载时才写入 `ImportedLibraryStore`，并继续由 `ReaderRuntimeScreen -> DownloadSession -> promoted artifact` 读取。完整章节离线 artifact 写入持久下载根，应用重启后 Reader 会优先复用。

详情页支持下拉更新和顶部刷新按钮。远程页刷新源目录，本地页刷新保存的目录快照或本地文件夹；都不转移网络、目录或 Reader 资源所有权。不同来源迁移采用显式复制：用户先选择目标源，默认按当前标题搜索并从候选作品中确认，也可手动填写目标原生 ID。整部漫画偏好会与目标源已有偏好合并；只有标题与序号同时匹配的章节才会在首次持久写入前重新解析并验证目标身份，然后填补目标源尚不存在的阅读位置和已读状态。目标源已有状态、源 URL、离线字节和原来源始终保留。SQLite schema 6 延续来源复合主键，并为旧库迁移诊断增加持久确认时间，因此不同来源可安全复用相同原生 ID。

远程图片交付 URI 可能变化，因此 `ImportedPageRecord` 单独保存源提供的稳定 page ID。每次打开远程章节会重新解析当前 manifest，再按稳定 page ID 迁移阅读位置。当前内置源只请求英文 safe/suggestive 内容，不包含账户登录、Cookie、反爬挑战或站点绕过。

所有 WebP 入口默认使用确定性的 `Flutter codec`，打开文件不会自动进入
FFI/texture。Reader 与文件夹切换页固定使用安全 codec；独立预览中的
`Native（实验）` 必须由用户显式选择并在确认对话框中再次确认；
初始化、上传或生命周期操作失败时回退 Flutter codec。Native 路径会验证 ABI
和锁定的 libwebp 1.6.0 运行时，并使用 source/cursor/frame ABI 解码真实 RGBA 帧。

“导入本地 WebP”读取单个 `.webp`。“导入图片文件夹”在 Android 使用持久化
SAF document-tree 授权，在桌面使用后台 isolate 递归枚举普通文件；两条路径都以
文件头优先识别 PNG、JPEG、GIF、WebP、BMP、TIFF、ICO、AVIF 和 HEIF，不信任
扩展名或大小写。导入结果转换为本地章节并通过 DownloadSession/promoted artifact
进入统一 Reader。章节记录和最后阅读页保存在本地 SQLite 目录库，应用重启后可从
首页重新打开；完全没有图片时才报告带扫描计数的空目录诊断。

Reader 媒体入口已使用真实 `LiveCoordinator` 和 `DownloadRegistry`。页面需求从
manifest identity 生成 `DownloadId`，经 AssetBundle/file/http transport 下载到
promoted artifact 后，播放器才读取最终字节。viewport target 更换或页面退出会
先 reconcile 掉旧需求，避免后台下载和旧 decode identity 残留。当前可见 WebP
仍固定使用 Flutter codec；native texture 只在独立预览中显式确认后启用。

Reader 默认以 `immersiveSticky` 进入并隐藏顶部、底部控制栏，轻触页面显示或再次隐藏。
底部滑杆直接提交有边界校验的 `ReaderController.requestPage`；旋转只改变页面呈现，
不会重写下载 identity。双指缩放和双击缩放由当前页 `InteractiveViewer` 持有，放大时
暂停 PageView 翻页，跳到其他页后重置旧页缩放。暂停和倍速继续复用原 `NativeWebpPlayer`
与 Flutter codec 路径，不旁路 download identity、telemetry 或 raster 下采样。Reader 的
章节下载命令现在委托 `ChapterDownloadService`：完整章节写入持久离线根并由索引验证，
重启后可直接读取；未完成下载仍由原 DownloadSession 恢复语义处理。下载任务通过
`ChapterDownloadSnapshot` 暴露权威页数、字节和终态；详情页订阅同一状态，因此退出再进入时
仍会显示进行中的章节任务。单章下载在共享封面上显示章节名和该章完成/总页数；“下载整本”
按目录聚合但仍逐章复用原 DownloadSession/artifact 所有权。只有活动任务显示自下而上的水位，
完成后恢复原封面并显示紧凑离线标记。下载管理以章节名为主标题，完成项不再显示进度条，并
支持逐章节取消、重试和删除离线文件；删除不会清除漫画、章节元数据或阅读记录。

Native 与 Flutter codec 使用同一个自适应物理显示目标：目标取实际预览区域的逻辑尺寸乘以设备 DPR，保持源图比例并按 8 个物理像素对齐。`RasterPlan` 再决定实际 decode raster：大图按目标下采样，小图保持原始画布，避免 animated codec 在合成局部子帧前先放大插值。极小素材显示时使用 nearest-neighbour，正常漫画页面继续使用平滑滤镜。Native 路径还会提前准备下一帧，并从帧时长中扣除准备耗时，避免解码时间把动画总时长拉长。

同步 native fixture 到 App assets：

```bash
./tool/sync_demo_webp_assets.sh
```

仓库检查会逐字节比较 App asset 与 native fixture，避免 UI 演示与 decoder
测试样本发生漂移。

## 生成 Flutter 平台工程

平台工程属于 Flutter App，而不是 monorepo 根目录。解压后进入仓库根目录 `zic/`，
可以直接运行：

```bash
./tool/bootstrap_platforms.sh
```

等价的手动命令是：

```bash
cd apps/app
flutter create \
  --empty \
  --project-name zic \
  --org dev.zic \
  --platforms=android,ios \
  .
```

不要在仓库根目录执行 `flutter create .`，否则 Android/iOS host 会生成到错误层级。

平台生成脚本会继续执行：

```bash
python3 tool/configure_platforms.py
```

该步骤会幂等地向 Android 主 manifest 加入 `android.permission.INTERNET`。对于已经存在的
Android host，更新源码后也应执行一次；发布 APK 不应依赖只在开发 host 中存在的权限。
推荐从仓库根目录使用统一运行入口：

```bash
./tool/run_android.sh
```

它会先生成或修复 host，再执行 `flutter run -d android`。直接运行 Flutter 命令前也可以
手动执行 `python3 tool/configure_platforms.py`。

## 测试目录

从仓库根目录运行全部 Flutter 测试：

```bash
./tool/test_flutter.sh
# 或
make flutter-test
```

脚本实际执行：

```bash
cd packages/reader && flutter test test
cd apps/app && flutter test test
```

纯 Dart package 测试：

```bash
./tool/test_dart.sh
# 或
make dart-test
```

运行 App：

```bash
cd apps/app
flutter run -d android
```

完整检查：

```bash
./tool/check.sh --require-toolchains
```

完整架构、规格、计划与实施状态位于 `docs/`。

## 构建 Android split APK

从仓库根目录运行：

```bash
./tool/build_android.sh release
# 或
make android-apk
```

脚本固定使用 `--split-per-abi`，分别生成各 ABI 的 APK，避免发布单个包含全部
native ABI 的 fat APK。调试构建可执行：

```bash
./tool/build_android.sh debug
```

## Native WebP 源码构建

项目不接受外部预编译的 Android libwebp 目录。host 与 Android native 构建都使用
`native/libwebp.lock` 固定的官方源码版本、仓库和 commit：

```text
libwebp 1.6.0
commit 4fa21912338357f89e4fd51cf2368325b59e9bd9
```

首次执行会把源码拉取到 `.deps/src/`，构建和安装结果写入 `.deps/build/` 与
`.deps/install/`。这些目录不进入版本控制。

Host smoke 与 Rust 测试：

```bash
./tool/check_webp.sh
./tool/test_rust.sh
```

Android 三 ABI 构建：

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
./tool/build_android_native.sh release
./tool/build_android.sh release
```

构建脚本通过 Android NDK CMake toolchain 从源码分别生成 `arm64-v8a`、
`armeabi-v7a` 和 `x86_64` 的 libwebp，再链接 `media_core`。默认从源码生成 PIC 静态归档并合入 `libmedia_core.so`，避免 Android APK 中的
版本化 SONAME 和传递依赖问题。`jniLibs` 默认只需要 `libmedia_core.so`。设置
`ZIC_ANDROID_WEBP_LINK=shared` 可用于显式的共享库调试构建。

网络受限时可指定一个受信任的源码 checkout：

```bash
export ZIC_WEBP_SOURCE=/path/to/libwebp
```

该 checkout 默认必须位于锁定 commit；只有明确的本地实验才使用
`ZIC_WEBP_ALLOW_UNPINNED=1`。构建会把上游 `COPYING`、`PATENTS` 和源码版本信息
写入 Android assets。native ABI v5 还会在运行时报告 decoder/demux 版本，
`NativeVersion.usesPinnedWebp` 可验证两者是否均为锁定的 1.6.0。
