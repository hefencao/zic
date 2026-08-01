# dev.76 Reader 立即退出与加载指示所有权审计

基线：`zic_v0.31.0-dev.75_compile-contract-ownership`。

本清单在修改产品源码前建立。Mihon 与 VibeVenera 参考仓库未并入、未修改。

## 一、问题清单

### 编译错误

- 当前设备日志是合法 JSONL，没有 Dart/Flutter/Android exception、assert、binder death 或 task failure。
- 本环境未安装 Flutter/Dart SDK，因此在源码修改前无法复现 analyzer/kernel 编译；必须以全仓引用搜索、仓库静态门禁和可执行的脚本检查补充，最终明确标为未验证。
- dev.75 handoff 声明上一轮编译闭包已完成，但本轮公共 API 删除后仍必须一次迁移所有生产与测试调用方。

### 产品错误

- `reader.ReaderView` 在整个 viewport 中心绘制 `reader-loading-indicator`，而具体页面媒体也拥有自己的页面内加载状态。纵向连续布局中，两者可同时可见，形成一个固定屏幕中心、一个随图片居中的双加载圈。
- `local_media_ui.LocalImagePlayer.showLoadingIndicator=false` 是由上层抑制页面加载反馈的兼容开关；它把同一“页面是否已经可呈现”拆成 Reader 与媒体组件两个权威来源。WebP 内部播放器仍会显示自己的加载圈，因此该开关不能稳定消除重复。
- 设备日志中当前页 4 的 WebP decode 在 163675µs（partial source ready）和 374724µs（artifact promoted）各启动一次，但在 Reader 于约 1.897s 退出前没有 `firstFrameReady`；相邻页 3/5 在约 212ms、页 2 在约 423ms 首帧完成。日志不足以证明解码错误，但说明当前页首帧是后续设备性能复验重点。
- 首页相同 cover identity 有重复 `homeCoverRequested`/`homeCoverSourceReady` 事件；这些命中 `durableCacheFile`，日志没有显示重复网络下载。它可能来自更新/历史等多个可见卡片实例，不在本轮 Reader 加载圈修复中改变缓存或首页行为。
- 耦合审查发现基线的 `PipelinePageStream` 仍公开 `EncodedSource`，`local_media_ui.NativeWebpPlayer` 仍直接创建 native cursor 与 Android texture presenter。按当前架构目标，decode/upload 的正确所有者应是 Pipeline；但仓库尚无可供 `pipeline_runtime` 注入的生产 `FrameUploader`，本轮若只搬走一半会造成不可运行的第二条链或回退到完整字节加载。因此本轮不伪装已闭合，记录为后续原子能力迁移债务，并禁止在 Reader/App 再新增同类入口。

### 性能问题

- 固定 viewport overlay 为 Reader 维护 `_readyPageKeys`、父级 setState 和全屏 Stack paint，只服务于冗余视觉反馈；应删除，不应触碰 Pipeline 的 +7/-3 下载窗口、+2/-1 解码窗口或 5/3/2 lane。
- 当前页 WebP 在完整 artifact 前进行一次 partial decode，随后完整 artifact 再解码。日志没有 failure；本轮不以缩窗、降并发或禁用 progressive 路径掩盖，并单独记录当前 encoded-source/decode 所有权未闭合。
- Reader 退出时 7 个 download demand 在约 1.897s 同批 detach；此前 artifact 已在约 0.637s 内全部 promoted。未观察到退出后继续接收字节或错误，生命周期本身没有日志证据表明泄漏。

### 测试错误

- `packages/reader/test/reader_navigation_test.dart` 明确断言加载圈必须属于 viewport，并要求其中心等于 `ReaderView` 中心；这是 ADR 0053 的旧产品假设，现已被真实纵向双加载圈证明退化，应改为断言 Reader 不建立全局加载 overlay。
- 页面内加载反馈应由 `local_media_ui` 的 owner package 测试；`reader` 测试只验证首帧回调/telemetry，不重复测试媒体加载状态。
- 新回归不得使用固定 pump 时长、lazy child `.single` 或文本包含匹配。

## 二、所有权清单

| 状态 / 资源 / 命令 / 生命周期 | 当前所有者 | 正确所有者 | 本轮处理 |
| --- | --- | --- | --- |
| Reader current page、方向、旋转、导航 revision | `reader.ReaderController` | `reader.ReaderController` | 保持 |
| viewport observation / `ReaderObs` | `reader.ReaderView` 采集，`reader_runtime.ReaderRuntimeScreen` 适配 | Reader Presentation | 保持 |
| 下载/预取/解码/上传 demand | `pipeline.ReaderBinding` + `pipeline_runtime.PipelineReaderSession` | Pipeline | 保持窗口和 lane |
| canonical page identity | `downloads.readerPageDownloadId`，经 `PipelinePageStream.identity` 只读投影 | downloads / Pipeline projection | 保持 |
| DownloadSession、artifact、partial、promotion | `downloads.DownloadRegistry` / `DownloadSession`，由 `PipelineReaderSession` 组合 | downloads / pipeline_runtime | 保持 |
| Reader pipeline session 创建/销毁 | `pipeline_runtime.PipelineReaderSessionHost` | pipeline_runtime host | 保持；Reader 只 detach 自己的 observation binding |
| 页面 transfer progress / artifact 可用性 | `pipeline_runtime.PipelinePageStream` | pipeline_runtime | 保持只读投影 |
| 页面 encoded source、native cursor、texture presenter | `PipelinePageStream.source` 泄漏给 `local_media_ui.NativeWebpPlayer`，后者直接 decode/upload | pipeline / pipeline_runtime 原子能力 | 识别既有债务；本轮不建立半迁移竞争链，后续须连同生产 `FrameUploader` 与 presentation-safe output 一次迁移 |
| 页面媒体 loading/ready/invalid | `local_media_ui.LocalImagePlayer`、`NativeWebpPlayer` 等具体媒体 widget | 具体页面媒体 Presentation | 统一为唯一可见加载反馈 |
| Reader 全局 `_readyPageKeys` 与 viewport spinner | `reader.ReaderView` | 不应存在第二权威状态 | 删除 |
| 首帧 telemetry 去重 | `reader._ReaderPageHostState._reportedFirstFrame` | reader page host | 保持；不再驱动全局 spinner |
| 页面真实尺寸 | `local_media_ui` 检测并通过 `ReaderPageRuntime.reportDimensions` 投影，Reader 保存 ratio | 媒体测量 + Reader 几何投影 | 保持 |
| `showLoadingIndicator` 抑制能力 | `LocalImagePlayer` 可由上层 setter-like 参数覆盖 | 不应暴露；页面媒体自行呈现 loading | 删除 API 与调用方 |
| 顶部网络进度条 | `reader_runtime.ReaderRuntimeScreen` 消费 `PipelineTransferProgress` | Reader controls 的只读投影 | 保持，不等同页面加载圈 |
| 下载按钮工作态小圈 | `reader_runtime.ReaderRuntimeScreen` 的用户命令按钮 | Reader controls | 保持，不是固定屏幕中心 |
| 首页封面响应字节 | `resource_cache.ResourceCacheManager` | resource_cache | 保持 |
| Mihon/Venera request plan 与隔离调用 | `plugin_host` / Android isolated runtime | plugin_host | 只读，不修改参考仓库 |

### 固定居中加载指示器全仓核对

- `reader.ReaderView`：全屏固定 overlay，和页面媒体重复；已删除。
- `local_media_ui.LocalImagePlayer` / `NativeWebpPlayer`：位于单个页面或图片 holder 内，是本任务要求保留的图片中间反馈。
- 首页/来源封面卡片：位于各自卡片约束内，不是屏幕级 overlay；保留。
- 漫画源首屏、外部源设置、迁移诊断、内置演示清单：对应整页异步数据初始化，页面尚无可展示内容，属于该 route 的唯一 loading 状态；保留。
- 漫画源分页尾项：位于 grid 尾部单元，不固定覆盖屏幕；保留。
- 下载、详情、插件仓库与设置中的小圈：绑定具体按钮、列表项或局部操作；保留。
- `reader_runtime`：顶部 `LinearProgressIndicator` 是 Pipeline transfer 的只读投影，圆圈仅在下载命令按钮内；均不是固定屏幕中心页面加载圈。

## 三、被否决方案清单

- **Reader viewport 固定居中加载圈 + 抑制页面内圈**：ADR 0053 曾采用，真实纵向拼接出现双圈，且 WebP 内部 loading 无法由外层统一抑制；本轮由新 ADR 明确取代，不得换名恢复。
- **Reader 维护页面 ready 集合作为第二权威来源**：与媒体 preview phase/first-frame 状态重复，删除后不得以 controller、facade 或全局 overlay 重新引入。
- **关闭页面内加载反馈，只保留全屏反馈**：不符合“加载圈跟随实际图片区域”，尤其连续布局和非当前可见页面；否决。
- **通过缩小预下载窗口、关闭 progressive decode 或降低并发隐藏加载/流量问题**：违反既定 Pipeline 策略，无实验数据与批准不得采用。
- **让 Reader 直接取消/销毁 DownloadSession 或 transport**：越过 `pipeline_runtime` 所有权；Reader 只提交 observation、命令和 detach 自己的 binding。
- **为通过旧测试保留兼容布尔参数或伪造 viewport loader**：测试假设错误时修测试，不保留生产无必要的兼容 API。
- **把 Mihon/VibeVenera 参考实现整体并入或修改参考源码**：本轮只读；不得建立竞争 Pipeline。
- **仅删除 `PipelinePageStream.source` 或仅把 cursor 移到 runtime**：缺少生产 uploader/output 投影时会打断现有 WebP 播放或制造双 decode 链；必须把 SourceFactory、decoder、uploader、output 生命周期作为原子能力迁移。
