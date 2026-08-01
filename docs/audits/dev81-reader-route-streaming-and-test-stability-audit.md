# dev.81 Reader 路由、Mihon 流式、上传生命周期与测试稳定性审计

## 问题清单

### 编译错误

- `MainActivity` 继承 `FlutterActivity`，却调用不可用的
  `registerForActivityResult`，Android Kotlin 编译失败。

### 产品错误

- Mihon adapter 将普通图片硬编码为 `requiresRuntimeTransform=true`；插件
  runtime 完整下载图片后才一次性返回正文。设备 Trace 中缓存页按 64 KiB
  增长，而多张 origin 页表现为数 MB `sourceReady` 后一次同长度
  `bytesCommitted`，因此流式首帧和接收进度从机制上失效。
- Download 进度 publisher 保存第二套 partial baseline，无法稳定表达一次
  writer/run 新增的 bytes。
- `UploadSession.detach/reset/dispose` 在异步平台 upload 未完成时调用
  `release(id)`。Trace 在快速 30↔31 页面 demand 切换后记录
  `Failure(texture): frame upload failed`，旧 revision 可污染新播放状态。
- 章节详情在 `Navigator.push` 前等待 `loadChapter`、remote refresh、artifact
  检查和 loader 组合，冷插件/网络使用户十几秒看不到 Reader。
- WebP/普通图 Presentation 仍有 top-center 与 center 分支，未形成统一居中。

### 性能问题

- 插件完整正文 RPC 使大图先占用插件网络与内存，再进行一次宿主复制，
  无法与下载/解码 lane 并行。
- 章节点击关键路径被插件解析和存储检查串行阻塞。
- stale upload 的失败会触发额外 task failure/retry 和 playback churn。

### 测试错误

- 三个 downloads 流式测试使用真实 loopback `HttpServer`、异步 close 和
  固定 30 秒 timeout，实际在 teardown 等待连接关闭而超时。
- 两个连续阅读 Widget 测试假设 lazy gap child 当前已挂载，并断言
  `offset > 580` 这类与 viewport/构建时机绑定的魔法阈值。
- App artwork gateway 另有两个真实 loopback `HttpServer` 测试，继承同一 teardown/网络时序风险。
- Reader 双击测试使用 80/50/400ms 固定 pump，仓库门禁甚至强制保留 400ms 等待。
- 旧静态门禁按测试标题切字符串，本身也迫使恢复脆弱实现。

## 所有权清单

| 状态/资源/命令/生命周期 | dev.80 当前所有者 | 正确所有者 | dev.81 动作 |
|---|---|---|---|
| Mihon 图片 request plan | adapter 直接标记完整 runtime transform | plugin_host/bridge 解析 plan，downloads 执行正文 | 新增 Mihon `resolveResource`; host direct stream，失败后 fallback |
| GET/HEAD 规范化 | `_openDirect` 内联判断 | downloads transport | 提取 `normalizeSourceResourceRequest`，零 body/实体 headers |
| 单次网络 run baseline | pipeline publisher 猜测 | DownloadSession | snapshot 新增 `networkStartLength` |
| active upload 与 slot release | detach 立即 release | UploadSession | 同 DecodeId upload 串行；queued/active 排空后 release；stale error 转 cancelled |
| 章节 route 呈现 | details/App 准备完成后 push | App route composition | 立即 push `DeferredReaderRoute`，route 内准备 |
| 媒体对齐 | 普通图/WebP 分支 | local_media_ui/texture Presentation | 统一 center |
| 连续阅读 extent/anchor | Reader Widget + lazy tree | Reader pure geometry owner | 新增 `ReaderVerticalGeometry` |
| transport 测试网络 | 测试自建真实 socket | downloads owner controllable capability | 注入 controlled `ByteResponse` stream |
| Android 文件结果 | 不适用的 Activity Result API | MainActivity | `ACTION_CREATE_DOCUMENT` + `onActivityResult` |

## 被否决方案清单

- 不通过等待完整下载、缩小窗口、降低并发或只下载当前页掩盖流式错误。
- 不把 Mihon complete-byte RPC 保留为正常路径；仅允许真实直连失败后的兼容回退。
- 不在 Reader/UI 建立第二套 committed baseline 或下载状态机。
- 不永久保留 texture；只延迟到 active upload 排空并遵守 output claim。
- 不在详情页等待 manifest 后才导航。
- 不添加 WebP 专用 padding、Transform 或独立 fit 规则。
- 不保留真实 socket、固定 sleep/timeout、lazy child `.single`、固定挂载数或
  魔法像素阈值测试。
- 不修改 +7/-3、+2/-1、current/transition 或 5/3/2 lane。

## Trace 结论

- 文件包含 2032 条有效 JSONL 事件。
- 前段缓存/session-copy 页面以 64 KiB 多次 `bytesCommitted` 增长；后段多张
  Mihon origin 页面分别以 3.6–6.8 MB 单次 commit 完成，证明 source-owned
  完整正文路径仍在正常 Reader 流程中。
- 页面 30→31→30 快速切换期间，page 30 upload 已开始，revision 随 demand
  改变并进入 idle；旧平台上传随后完成/呈现，紧接着记录 upload failed 和
  `Failure(texture): frame upload failed`。这支持 slot release 与 active Future
  竞态，不是 decode 窗口不足。
- Trace 从 Pipeline Reader session 创建后开始，不能覆盖点击详情到 route
  创建前的十几秒；该延迟由源码导航前 await 链确认。

## 实际修改

- Mihon bridge 增加 request-plan `resolveResource`；adapter 的 retry 重新解析
  plan。downloads transport 先直接流式，刷新 plan 后仍失败才调用
  `loadResource` fallback。
- DownloadSnapshot 增加 owner-owned `networkStartLength`; progress publisher
  删除 `_existingBytes/_networkStarted` 第二状态源。
- UploadSession 对同一 `DecodeId` 的平台 upload 串行化，并在 queued/active
  操作排空后 deferred release；revision/cancel 变化后所有 Failure/Object 结果
  只返回 cancelled。
- 详情页传入 loader，App 立即 push deferred Reader route；准备工作移入 route。
- `MediaAspectViewport` 与 native texture viewport 统一 center。
- 用 controlled Stream/Future 重写 downloads/App artwork/upload/route 回归；连续阅读 gap、
  extent、anchor 测试迁到纯 `ReaderVerticalGeometry`。Reader 双击判定改用注入的
  `MonoClock`，测试不再 pump 固定时间或 `pumpAndSettle`。
- 修复历史静态门禁，不再依赖测试标题、固定 400ms 等待或旧内联实现 token。
- Android Trace export 使用 FlutterActivity 支持的 document Intent 生命周期。

## 验证结果

当前环境已通过仓库结构、Dart directive、Pipeline compile boundary、dev.75–
dev.81 所有权门禁、Reader/Pipeline/UI、Android、Mihon ABI/entry/payload/
classloader/read-only/chapter、Venera network/headers/preflight/bootstrap、外部源与
native header 契约。聚合验证在 Venera network 慢项处达到外层时限；该项及其余
尾项均已拆分并逐项执行通过。用户提供的 libwebp 1.6.0 源码也通过 host build、
incremental 和 loop fixtures。

首次完整 ZIP 使用系统 `unzip` 重新解压后，720 个文件通过逐文件 SHA-256 与执行
权限往返比对；解压副本再次通过 dev.75–dev.81、Reader/Pipeline/UI、Android、
Mihon、Venera、外部源、native header 和 libwebp 关键契约。最终审计文字写回后
已重新打包，并再次执行字节/权限比对与 dev.81 关键门禁。

当前环境没有 Flutter/Dart SDK、Cargo/rustc 和 Android Gradle wrapper，因此
不能声称 `flutter analyze`、真实 Dart/Flutter tests、Rust tests、APK/kernel
snapshot 或真机行为已通过。用户错误报告中的失败测试已在源码中替换，但必须在
其 SDK 环境重新执行确认。
