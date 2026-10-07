# dev.83 预下载、自适应与连续拼接审计

## 问题清单

### 编译错误

- `packages/sessions/lib/src/live_coordinator.dart` 使用 `DecodeSnapshot`、`DecodeState`、`UploadState`，但只导入 Registry，没有导入定义这些 owner 类型的 `decode_session.dart` 与 `upload_session.dart`，导致 kernel snapshot 失败。

### 产品错误

- `readerPipelineProfileFor` 仅在页面 scheme 为 `venera-resource` 时启用前 7/后 3、预解码前 2/后 1、5/3/2 lane。Mihon、HTTP 和其他远程章节错误落入 standard profile，Trace 中多数 policy decision 只有 7 个总下载 demand，而不是 current + forward 7 + backward 3。
- 每漫画自适应把插件返回的 `readingDirection=vertical` 直接保存为 0.9 置信度 `source-hint`。该字段只是来源默认方向，不是 VibeVenera `adaptiveType` 这种显式高置信度布局声明，因此明显 Animated WebP 会先被错误切成纵向。
- 当前 adaptive profile 只存在于 mounted Reader 内存，不随每漫画设置持久化；重新进入时重复从来源方向开始，运行时动画/页面几何证据不能成为每漫画权威结果。
- 纵向拼接的 page extent 以逻辑浮点计算，内部 `FittedBox.fitWidth` 又按自己的比例计算显示高度。边界可能落在半个物理像素，滚动变换后舍入方向变化，形成会随位置出现/消失的 1–2 像素细线。

### 性能问题

- 非 Venera 远程 Reader 只生成较小下载窗口，当前页移动后才逐步创建后续 request plan，失去 VibeVenera 稳定窗口的预下载收益。
- adaptive 每次进入重新分类，既重复工作，也可能在来源提示、页面几何和动画事实之间来回切换。

### 测试错误

- 不新增真实网络、固定等待、lazy child 数量、魔法滚动像素或精确 double 相等测试。
- 预下载使用纯 `RoleResolver/HeuristicPolicy` plan 断言；adaptive 使用纯 classifier；拼接使用纯物理像素边界值对象和一次 Widget layout，不依赖滚动时序。

## 所有权清单

| 状态/资源/命令 | 当前所有者 | 正确所有者 | 处理 |
|---|---|---|---|
| decode/upload snapshot 类型 | `DecodeSession` / `UploadSession` | 同左 | Coordinator 显式导入 owner 类型，不复制 enum/facade |
| Reader 下载/预解码窗口 | `pipeline_runtime.ReaderPipelineProfile` + `pipeline.RoleResolver` | 同左 | 所有 Reader 统一稳定 7/3、2/1、5/3/2；transport 差异不改变 policy |
| adaptive 样本与分类 | mounted `ReaderRuntimeScreen` 的零散判断 | `reader_runtime.AdaptiveReaderClassifier` | 参考 VibeVenera：封面排除、至少两份几何/动画证据、0.60 应用、0.80 停止 |
| 每漫画 adaptive profile | 无持久 owner | App preferences 的 `ComicReaderSettings` | 仅持久化 profile 值；Reader 通过 `ReaderSessionSettings` 原子消费/更新 |
| 手动方向覆盖 | App/Reader settings | 同左 | 始终高于 adaptive profile |
| 来源 readingDirection | plugin/catalog manifest | 仅作为无 adaptive 结果时的 fallback | 不再构造 0.9 adaptive profile |
| 纵向页面 extent | `ReaderVerticalGeometry` | 同左 | 按 DPR 对每页高度进行物理像素对齐，累计边界保持整数物理像素 |
| stitched 页面内部 fit | `MediaAspectViewport` | Presentation 但服从 Reader 已分配几何 | fitWidth 在权威 page box 内填满，不再次产生独立浮点高度 |

## 被否决方案清单

- 不缩小下载/解码窗口或降低 lane 并发来掩盖预下载失效。
- 不在 App/Reader 新建第二套预取器、下载队列或图片字节缓存。
- 不把所有 WebP 后缀直接判为动画；需要实际动画 hint/header/runtime 证据。
- 不继续把插件来源方向当成 adaptive 高置信度事实。
- 不用负位移、页面重叠、裁切内容或额外 1–2 像素遮罩隐藏接缝。
- 不通过固定 pump、真实 socket、lazy child `.single` 或精确浮点相等证明修复。

## Trace 与 VibeVenera 对照

- 本次 Trace 共 3913 条。第一 Reader 会话在 standard profile 下 policy decision 多为 4–7 个总下载 demand；第二会话虽出现 7 个总 demand，也仍不是前 7/后 3 的 11 个稳定集合。
- 第二会话从 page 77 跳到 155 后，窗口内 151–159 的若干页面只有 demand/detach，没有在当前页面完成前稳定进入 receiving，说明 policy profile 与实际预下载意图不一致。
- VibeVenera `DynamicPreloadPolicy.stableWindow` 固定 `downloadNext=7/downloadPrev=3`、`decodeNext=2/decodePrev=1`，页集合不随帧水位伸缩；帧水位只改变目标 frame depth。
- VibeVenera adaptive classifier 排除多页漫画封面，需要至少两份非封面页面几何或两份实际动画样本；0.60 开始应用，0.80 才停止评估，手动每漫画设置始终覆盖 profile。

## 实际实施结果

- `live_coordinator.dart` 已直接导入 `decode_session.dart` 与 `upload_session.dart`，未复制 snapshot/state enum，也未扩大 public facade。
- `ReaderPipelineProfile` 收敛为唯一 `stable` 值；Mihon、Venera、HTTP、本地与 artifact 恢复均生成前 7/后 3下载、前 2/后 1预解码、current/transition 上传和 5/3/2 lane。删除无生产调用的 `standard/sourceStreaming` 兼容别名。
- 自适应分类器按 VibeVenera model v4 迁移 metadata、category/language fallback、tag weight、页面几何评分与 softmax；多页漫画排除封面，几何和实际动画均要求至少两份样本。普通来源方向、manifest `animatedHint` 和 WebP 后缀不再预填动画/纵向 profile。
- `AdaptiveReaderProfile` 连同 model version、confidence、basis、samples 与 metadata fingerprint 写入 `ComicReaderSettings`，按 `sourceId + comicId` 持久化；手动方向覆盖仍最高优先级。
- 连续 Reader 页面 extent 按设备 DPR 量化到同一物理像素网格；stitched 普通滚动移除每页独立 RepaintBoundary/ClipRect，媒体和 texture 在 Reader 权威 page box 内直接填充。没有加入 overlap、负位移、遮罩或裁切漫画内容。
- App 版本已更新为 `0.31.0+83`。

## 实际验证结果

已在工作树通过：仓库结构、317 个 Dart 文件/120 个测试文件结构检查、library directive、Pipeline compile boundary、dev.75–dev.83 所有权门禁、Reader streaming/layout、Pipeline demand、source binding、UI Architecture、纵向几何/封面/Trace、Android runtime/Trace、外部来源设置/登录、Mihon ABI/entry/payload/read-only/chapter/classloader、Venera network/native/header/preflight/bootstrap 与 native header 契约。

使用用户提供的 `libwebp-1.6.0.zip` 在独立临时依赖目录完成 host source build，并通过 incremental、blend 与 finite-loop fixture。Mihon 与 VibeVenera 参考树保持只读。

当前容器没有 Flutter/Dart SDK、Cargo/rustc、Gradle 或 Android wrapper，因此未执行 analyzer、真实 Dart/Flutter 测试、Rust 测试和 Android kernel/debug/release；这些项目不得由静态门禁代替，仍列入设备/toolchain 复验。

## 完整 ZIP 解压复验

首次完整 ZIP 含 729 个项目文件；使用系统 `unzip` 解压后，全部文件的 SHA-256 内容与 owner 执行权限逐项一致，未发现 `.git`、`.dart_tool`、`build`、`.gradle`、`target`、`.deps`、`__pycache__`、`.pyc` 或 `.class`。解压副本再次通过仓库结构、directive、Pipeline compile boundary、dev.83、Pipeline demand、Reader layout、纵向几何/封面/Trace、Android、source binding、UI Architecture、Mihon 全部契约、Venera 全部契约、外部来源/login、native header 与用户提供 libwebp 1.6.0 host fixtures。

