# dev.78 Reader 输出、重入与诊断导出审计

基线：`zic_v0.31.0-dev.77_atomic-pipeline-media-runtime`。

本轮只修复 dev.77 原子迁移暴露出的编译闭包、页面几何、重入生命周期、章节导航延迟与 trace 导出问题。Mihon 与 VibeVenera 参考仓库保持只读；既定 +7/-3 下载、+2/-1 预解码、current/transition 上传和 5/3/2 lane 不变。

## 一、问题清单

### 编译错误

- `pipeline_runtime.PipelineMediaRuntime` 公共接口返回 `RendererKind`，但文件未导入定义该领域值对象的 `domain` package，导致 `RendererKind not found`。
- `UploadRegistry.hasRunnablePlayback` 直接比较 `PlaybackState.running`，却既未导入该内部 enum，也越过了 `UploadSession` 的状态封装，导致编译失败。

### 产品错误

- Pipeline native WebP decoder 将 viewport decode target 当作必须输出的精确宽高，源图被分别按 X/Y 缩放，宽高比不同的页面因此纵向压缩或拉伸。
- 页面移出 decode/upload demand 后，已消费的一帧不再留在 holder，但同一 `DecodeSession` 保留了已到 EOF 的 cursor。页面重新进入窗口时继续从 EOF 解码，无法重新产生首帧，Presentation 只剩页面内 loading。
- 漫画详情页会在后台对所有未知页数章节调用 `loadChapter` 做 page-count preflight；点击目标章节的 `loadChapter` 可能排在同一插件/source 调用链之后，形成十几秒导航阻塞。
- 详情页和统一导航入口重复写入“已读”状态，非关键持久化 I/O 被放在进入 Reader 的同步路径上。
- Debug Trace UI 使用最多 500 条、允许合并高频事件的诊断投影作为复制/导出来源。导出结果不是原始诊断记录；本次附件恰好只有 132 条交替的 `readerObservation`/`pageTransition`，缺少同 session 的下载、解码、上传与错误上下文。

### 性能问题

- 非等比 native scale 不仅破坏画面，也可能按过大的 viewport 高度生成无必要像素和纹理上传。
- 自动全章节 page-count preflight 会在用户尚未打开章节时请求正文，竞争插件、网络、artifact 与主线程调度资源。
- trace 高频事件若只保留 UI 投影，排障时需要重复复现；若无限保存又会无界占用内存。需要“有限原始导出环 + 更小可合并 UI 投影”两平面。

### 测试错误/缺口

- dev.77 静态门禁没有覆盖 `pipeline_media_runtime.dart` 的 `RendererKind` 导入闭包和 registry 对 session-internal playback enum 的泄漏。
- native WebP fixture 只验证可解码和循环，没有验证宽图/长图在目标边界内保持宽高比。
- DecodeSession 测试未覆盖“静态页首帧已消费 -> detach -> 相同 epoch 重新 demand”的 replay。
- App 测试没有禁止详情页为显示页数主动加载全部章节正文。
- Debug Trace 测试只覆盖 UI ring/coalescing，没有验证复制和文件导出使用未合并的原始 ring。

## 二、所有权清单

| 状态 / 资源 / 命令 / 生命周期 | dev.77 当前所有者 | 正确所有者 | dev.78 处理 |
| --- | --- | --- | --- |
| Renderer identity | `domain.RendererKind`，但 runtime 接口漏导入 | `domain` 值对象；`pipeline_runtime` 仅引用 | 补齐显式依赖与编译门禁 |
| Upload playback running 判断 | Registry 读取 timer enum | `UploadSession` 封装 timer，Registry 只问能力布尔值 | 新增只读 `playbackRunning` |
| Decode target 宽高 | 被 native decoder 当精确输出尺寸 | Pipeline 提供最大物理边界；decoder 依据源 canvas 等比 fit | native cursor 输出实际 fitted 尺寸 |
| Android texture 尺寸 | 由 DecodeId 最大边界创建 | uploader 以首个 decoded frame 的实际尺寸创建并复用 | 校验同 identity 后续帧尺寸稳定 |
| 页面重新进入时 cursor | DecodeSession 保留 EOF cursor | DecodeSession 根据 demand 生命周期决定重建 | detach 后下一次 fill 原子 replay |
| 章节正文加载 | 详情页 page-count preflight 与目标打开竞争 | 仅目标打开/下载路径请求正文；Catalog 页数是元数据投影 | 删除自动全章节 preflight |
| Reader 导航 | 详情页和 DemoHome 双入口共同写已读 | 统一导航入口创建 Reader；已读持久化非阻塞提交 | 删除重复写并移出同步关键路径 |
| UI trace 列表 | `DebugTraceLog.events` 小型合并投影 | Debug UI 投影 | 保持最多 500、允许合并 |
| 原始 trace 导出 | 不存在，错误复用 UI 投影 | `DebugTraceLog` 独立有界 raw export ring | 复制/导出/filter 改用 raw ring |
| trace 丢弃计数 | 只统计 UI 投影 trim | raw 与 UI 分开计数 | 导出状态显示 raw dropped |

## 三、被否决方案清单

- **通过 `BoxFit.fill`、负位移、页面重叠或固定高度掩盖压缩**：不修 decode 几何，继续破坏漫画内容；否决。
- **让 Presentation 根据纹理尺寸二次拉伸回去**：会造成二次采样且无法恢复已丢失比例；正确位置是 native decode target 计算。
- **为避免压缩统一使用源图原尺寸**：可能生成超出设备/预算的巨大纹理；应在 decode 最大边界内等比 fit。
- **页面离开窗口后永久保留所有 decoded frame/texture**：会把无限加载换成长章节显存累积；必须允许退休并在重入时 replay。
- **每次 EOF 都自动 rewind**：会把有限动画和静态图变成无条件循环；只允许 demand detach 后的下一次重入重建 cursor。
- **缩小 +7/-3 或 +2/-1 窗口、降低 lane 并发**：不能用策略退化掩盖 cursor replay 或页面请求竞争；否决。
- **保留全章节 preflight，但给点击章节更高 UI 优先级**：正文调用仍在 App 重复发起并可能被插件串行化；页数显示不应拥有正文加载。
- **先等待“已读”写入成功再导航**：阅读状态持久化失败不应阻塞 Reader presentation；改为统一入口非阻塞提交。
- **把 Debug UI 的 500 条上限直接调大**：高频重建和列表成本上升，且合并后仍不是原始导出；需要双 ring。
- **原始 trace 无界保存或打印完整插件 token/Base64**：内存与隐私风险；raw ring 必须有界且继续使用 hash/长度摘要。

## 四、实际实施

- `pipeline_runtime` 显式导入 `domain`，使公共 `RendererKind` 返回类型形成完整 package 编译闭包。
- `UploadSession` 新增只读 `playbackRunning`；`UploadRegistry` 不再识别或比较 session 内部 `PlaybackState`。
- native WebP decoder 将 `DecodeId.physicalWidth/physicalHeight` 解释为最大输出边界：先读取源 canvas，再按单一比例等比缩小；尺寸已经位于边界内时不放大。
- decoded frame、Pipeline output 与 Android texture 使用 fitted 实际尺寸；同一稳定 `DecodeId` 若后续帧尺寸变化，uploader 会退休该 slot 并失败，而不是静默拉伸或写入错误尺寸纹理。
- `DecodeSession.detach` 标记下一次 demand 重入；若 holder 已空，则在下一次 `fill` 前释放 EOF cursor 并以相同 source epoch 重建。仍有 retained frame 时继续复用，不额外解码。
- 删除远程详情页的全部 page-count preflight worker、状态集合和“正在加载页数/失败”第二状态源；未知页数稳定投影为“页数待加载”。
- 目标章节持久化完成后不再同步执行全库 `_reloadLibrary()`；详情页先做本地已读投影，统一导航 owner 在进入 Reader 前以非阻塞任务持久化，失败通过 snackbar 明确报告。
- `DebugTraceLog` 新增最多 20,000 条的有界 raw export ring，并保留最多 500 条的可合并 UI ring。会话筛选、复制与 JSONL 文件导出使用 raw ring；UI 展示 raw 缓冲长度和丢弃计数。
- 文件导出改为可注入原子能力，生产实现使用 `file_selector`；取消保存保持静默，真正异常明确显示“Trace 导出失败”。

## 五、删除与引用审查

本轮没有删除仍有生产用途的完整源码文件。删除的是以下重复或越权实现：

- 详情页 `_pageCountPreflightGeneration`、worker queue、失败/进行中状态和全部正文预取方法；
- chapter tile 的 `pageCountLoading/pageCountFailed` 兼容字段；
- 章节点击关键路径中的同步全库 reload 和重复已读等待；
- Registry 对 `PlaybackState.running` 的内部 enum 依赖；
- 将 Debug UI 合并投影误作原始导出数据的路径。

全仓引用检查确认：

- 生产代码不存在 `_pageCountPreflight`、`pageCountLoading` 或 `pageCountFailed`；
- `_ensureSourceChapter` 内不存在 `await _reloadLibrary()`；
- Registry 不再出现 `PlaybackState.running`；
- Reader/Pipeline 窗口、lane、request-plan identity 与 artifact identity 未变。

## 六、验证结果

当前环境已实际通过：

- 仓库结构、Dart library directive 顺序与 `pipeline_runtime` 编译边界静态检查；
- dev.75、dev.76、dev.77 与新增 dev.78 所有权门禁；
- Reader streaming/output、纵向几何、Pipeline demand 稳定性、UI Architecture 与 source-resource 原子绑定契约；
- Android runtime 依赖、native header、Mihon ABI/入口/payload/只读/章节/classloader 契约；
- Venera 网络策略、native binary、响应头、Reader preflight、bootstrap 与外部来源登录契约；
- 使用用户提供的 libwebp 1.6.0 本地源码完成 host build，以及 incremental decode、blend、finite-loop fixtures。

新增但因当前环境缺少工具链而未实际执行的测试：

- `DecodeSession` detach/reentry cursor replay Dart 单元测试；
- fitted output 与 UploadSession 实际尺寸 Dart 单元测试；
- 无 page-count preflight、raw copy/export Flutter Widget 回归；
- Rust `fit_dimensions` 与 FFI aspect-fit 单元测试。

当前容器缺少 Flutter/Dart SDK、Cargo/rustc 与 Android Gradle wrapper，因此 `flutter analyze`、Dart/Flutter tests、Rust tests、APK/kernel snapshot 和 Android 真机纹理/导航/导出验证仍需在具备工具链的环境执行。静态门禁与 libwebp C smoke 不冒充这些验证。
