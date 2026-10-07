# dev.80 流式状态、统一栅格与 Trace 导出审计

## 问题清单

### 编译错误
- 当前设备报告没有新增 Dart 编译错误；dev.79 的 compile boundary 必须保持闭合。
- Debug 导出默认实现直接调用 `file_selector.getSaveLocation`，Android 后端抛出 `getSavePath() 未实现`。这属于能力组合错误，不应由 Debug 页面直接选择平台实现。

### 产品错误
- Reader 在正文已经持续收到字节时，进度 UI 仍将 `totalLength == null` 的状态显示为“尝试连接”，直到 artifact 完成。连接、接收和完成状态没有以 `committedLength` 为依据区分。
- WebP native cursor 虽能看到增长中的 source，但首帧生产与 source 增长调度仍缺少设备可观测闭环；必须验证每次 source revision 都能驱动等待中的相同 decode demand，并且 UI 不把已接收字节误投影为连接中。
- 普通图片、完整字节 WebP、Pipeline WebP 和 Android texture 分别解释 decode target、原始比例与 `BoxFit`，导致先后出现普通图压缩、WebP 拉伸。
- `DecodeTarget.fit` 独立对齐宽和高，可能破坏源比例；native WebP 又使用另一套 fit 算法且不执行统一 8 像素栅格策略。
- Debug 文件导出在 Android 使用不受支持的 `getSaveLocation/getSavePath`；复制一次性向系统剪贴板提交最多 20000 条 JSONL，可能因平台载荷限制失败，且异常未被捕获。

### 性能问题
- 未知总长度时 UI 缺乏接收态，用户无法判断连接和持续传输，容易重复退出/重进并放大请求。
- 多套缩放决策会产生不同 decode identity、重复解码和 texture 重建。
- 将完整 raw trace 一次性复制到系统剪贴板可触发 Android Binder/剪贴板大小限制。

### 测试错误/缺口
- 缺少“总长度未知但 committedBytes 增长时必须处于 receiving，而非 connecting”的 owner 回归。
- 缺少普通图片与 WebP 共用同一 aspect-preserving、8 像素对齐栅格计算的回归。
- 缺少 native WebP fit 与 Dart 栅格值对象一致性的静态/fixture 契约。
- 缺少 Android document export capability 与不支持平台错误降级的测试。
- 缺少大体积 raw trace 复制上限、UTF-8 边界和异常反馈测试。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | dev.80 动作 |
|---|---|---|---|
| 网络连接/接收/完成语义 | Reader UI 根据 nullable fraction 临时推断 | `pipeline_runtime` 只读 transfer phase | 投影明确 phase；Reader 只渲染 |
| source 增长 revision | `DownloadSession/Ingress` | 不变 | 保持每次增长通知并补可观测回归 |
| 屏幕物理边界与 8px 对齐 | `DecodeTarget`、Rust WebP、Flutter Image 各自计算 | `pipeline` 的单一纯值对象 | 所有 decode/render 路径消费同一算法 |
| 原始图片比例 | static provider、WebP surface、texture viewport 各自推断 | `local_media_ui` Presentation viewport + pipeline 栅格元数据 | 一个统一 media viewport，禁止按格式分支拉伸 |
| Android 文档保存 | Debug 页面直接调用 `file_selector` | App composition 注入的 storage/platform facade | Android SAF exporter；页面只调用能力 |
| Trace 复制 | Debug 页面直接提交完整字符串 | Debug presentation 的有界复制投影 | UTF-8 有界文本、显式截断和错误反馈 |
| raw trace 完整导出 | `DebugTraceLog` raw ring | 不变 | 文件导出保持完整 raw ring |

## 被否决方案清单

- 不通过等待下载完成后再解码来“稳定”流式播放。
- 不用伪造百分比掩盖未知 Content-Length；明确区分 connecting 与 receiving。
- 不在普通图片、WebP、texture、封面各写一套比例和 8 像素对齐判断。
- 不通过 `BoxFit.fill`、负位移、裁切或双重反向拉伸修正比例。
- 不恢复 Presentation-owned WebP cursor/decoder，也不缩小 +7/-3、+2/-1 或 5/3/2 lane。
- 不继续依赖 Android 未实现的 `file_selector.getSavePath()`。
- 不因复制过大而退回合并后的 500 条 UI trace；完整数据仍可文件导出，复制使用明确有界子集。

## 实施结果

- `IngressSnap` 增加 `revision`；append、source 创建、seal、reset 与 failure 均推进 revision。`DownloadSession` 的 source listener 用 revision 而不是单次 ready 边沿判断变化。
- `LiveCoordinator` 增加 `_decodeSourceRevisions`。初始 decode 记录其开始消费的 source revision；follow 任务循环比较最新/已消费 revision，排空活跃任务期间的新增长度，并让重复 queued follow 无操作退出。download/decode demand 移除和 session dispose 都清理 revision map。
- `PipelineTransferProgress` 增加 `idle/connecting/receiving` phase 和 `receivedBytes`；未知总长度不伪造百分比。
- 新增 `AlignedRasterSize`。宽高作为一个 pair 选择，使用整数相对 aspect error 比较、最大面积 tie-break 和 8 像素对齐；`DecodeTarget.fit`、静态 `ResizeImage` 与 native WebP 使用同一 fixture。
- `MediaAspectViewport` 改为 child-fit builder：已知原图几何时外层按原比例 fit、内部 renderer fill 该盒；未知几何时直接把请求 fit 交给 renderer。直接文件图片不再因缺少预解析尺寸而 fill viewport。
- Pipeline WebP surface 尺寸只作非权威回退，不能覆盖 prefix/header 原图尺寸。WebP prefix 读取改为按最大 committed length 排空，异步读取期间的新 chunk 不会被 guard 吞掉。
- Debug Trace Android 文件导出改为 App-owned MethodChannel + SAF `CreateDocument`；Debug 页面无 `file_selector` 依赖。复制独立限制 64 KiB UTF-8，显示 copied/total 并捕获平台错误。
- `tool/check.sh` 纳入 dev.79/dev.80 静态门禁；新增 ADR 0064。

## 删除/替代内容

- 替代普通图片、完整动画和 Pipeline surface 各自默认 `BoxFit.fill` 的分散判断。
- 替代 Dart double 比例近似与 Rust 独立 fit 的不同比较方式，统一为整数 fixture 契约。
- 替代仅用 boolean `_streamingPrefixSyncing` 丢弃并发 prefix 更新的路径。
- 替代 Android Debug Trace 对 `file_selector.getSaveLocation/getSavePath` 的直接依赖。
- 没有删除有效生产文件，没有恢复 Presentation cursor，也没有修改窗口或 lane。

## 验证结果

已在当前环境通过：

- Dart 结构与 library directive 顺序检查；
- Pipeline runtime compile boundary；
- dev.75–dev.80 所有权门禁；
- Reader streaming、纵向几何、封面与 Trace 静态契约；
- Android runtime/config、Mihon/Venera 和 UI/source-resource 契约，且已在系统 `unzip` 解压副本复验；
- 使用用户提供的 libwebp 1.6.0 本地源码完成 host build，并通过 incremental、first-frame-before-complete、blend 与 finite-loop fixtures；同一检查已在系统 `unzip` 解压副本复验。

当前环境没有 Flutter/Dart SDK、Cargo/rustc、Gradle/Android wrapper，因此 analyzer、Dart/Flutter tests、Rust tests、APK/kernel snapshot 和真机行为未验证。静态门禁与 C/libwebp smoke 不替代这些项目。
