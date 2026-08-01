# ADR 0067：统一稳定预下载、每漫画自适应证据与物理像素拼接

## 状态

Accepted。预下载决策取代按 Venera URI scheme 选择窗口的实现；自适应部分取代 ADR 0063 中临时的 source-direction/runtime-animation 覆盖逻辑；拼接部分补充 ADR 0064 的统一栅格要求。

## 背景

设备 Trace 中同一章节中部的 `policyDecision` 长期只有 7 个总下载 demand，而既定窗口应为 current + forward 7 + backward 3，共 11 个。根因是 `readerPipelineProfileFor` 仅对 `venera-resource` 选择 7/3、2/1、5/3/2，Mihon、HTTP、本地与恢复 artifact 走了另一套 3/2/1 profile。

每漫画自适应此前把普通 `ChapterManifest.readingDirection=vertical` 当成 0.9 置信度 adaptive 事实，且结果只存在于 mounted Reader。来源默认方向不是显式 adaptive metadata；明显 Animated WebP 因而可能先被错误切到纵向，重新进入又重复错误推断。

连续拼接的页面高度、内部 fit 与外部纹理层分别舍入。即使逻辑高度相等，独立 `FittedBox`、`ClipRect` 和 `RepaintBoundary` 仍可能在滚动的分数像素变换下暴露 1–2 像素背景线。

## 决策

1. 所有 Reader source kind 使用一个不可变 `ReaderPipelineProfile.stable`：
   - encoded/download：前 7、后 3；
   - decode warm：前 2、后 1；
   - upload：仅 current/transition；
   - lane：5/3/2；
   - `PolicyGuard.maxDownloadDemands=11`。
   transport、插件和 cache 能力不得改变 Reader demand window。
2. 删除只做同值转发、生产无调用的 `standard`/`sourceStreaming` profile 别名。
3. 每漫画自适应迁移 VibeVenera 的可移植逻辑：
   - model version 4；
   - 0.60 应用、0.80 终止；
   - 多于两页时排除封面；
   - 至少两份非封面几何或两份实际动画证据；
   - 使用相同页面比例评分、tag weight、category/language fallback 和 softmax confidence；
   - title/tag/category/language/显式 sourceType 等 metadata 可以提供可移植证据；
   - 普通 `readingDirection` 只决定无 adaptive 结果时的 fallback，以及 paged 的 LTR/RTL，不得创建 vertical profile。
4. adaptive profile 与 metadata fingerprint 作为 `ComicReaderSettings` 的值持久化。手动漫画级方向始终优先；metadata/model 变化使旧 profile 失效。
5. `.webp` 后缀与 manifest `animatedHint` 都不等于实际解码动画证据。本地导入仅对 GIF 写入固有 hint；自适应动画 profile 只由明确 metadata 或至少两页运行时动画能力建立。
6. stitched page extent 由 `ReaderVerticalGeometry` 按 DPR 对齐到同一物理像素网格。相邻 bounds 必须完全相等，不增加 overlap、负位移或遮罩。
7. stitched Presentation 使用 Reader 分配的权威 page box：
   - `MediaAspectViewport` 不再计算第二个 fitWidth 高度；
   - `NativeTextureViewport` 在 `BoxFit.fill` 下直接填充，不创建第二层 `FittedBox`；
   - 普通 stitched 滚动不为每页创建独立 `RepaintBoundary` 或 `ClipRect`；缩放时仍裁切到页面边界；
   - stitched texture 使用低过滤质量以避免边缘 mip 采样。
8. Coordinator 需要的 `DecodeSnapshot/DecodeState/UploadState` 必须直接从 owning session 文件导入，不复制或扩大 facade。

## 后果

- Mihon、Venera、HTTP、本地与 artifact 恢复页面具有相同稳定预下载和预解码集合。
- 自适应结果按漫画稳定保存，来源 vertical 不再压过实际动画/页面几何。
- Animated WebP 标题或明确 tag 可在解码前分页；没有 metadata 时等待两份真实证据。
- 连续页面共用物理像素边界和直接 texture fill，接缝不再依赖滚动位置。
- 测试使用纯 policy plan、纯 classifier、纯几何和确定性 Widget tree，不依赖网络、固定时间或 lazy child。
