# dev.92 静态/有限动画输出生命周期审计

## 问题清单

### 编译错误

- `packages/storage/test/artifact_test.dart` 对 `Stream.toList()` 传入不存在的 `growable` 命名参数，导致测试文件无法加载。产品 `Artifact` API 无误，本轮只修测试调用。
- 本轮审查新代码时发现 `UploadSession.present` 的 `authoritativeStatic` 最初定义在条件块内却用于块外 Trace；已提升为方法局部值，关闭真实 Dart 编译作用域遗漏。

### 产品错误

- dev.91 只在 output 因 demand detach 或 frame budget 被退休时重建 consumed cursor；它没有覆盖 playback timer 自己推进 output 的路径。
- 静态 WebP 首帧时长为 0，但 UploadSession 仍启动 timer。timer 立即到期后旧逻辑先退休当前 output，再唤醒 decoder；静态 cursor 只能返回 EOF，页面永久 loading。
- 有限动画存在同类错误：最后一帧到期后若先删除 output，再发现 decoder ended，会丢失本应冻结的最后一帧。
- 下一帧读取、解码或上传暂时较慢时，先删除旧 output 会产生不必要的 loading 闪烁，即使最终 successor 可以到达。

### 性能问题

- 零时长静态帧会制造无效 `playbackFrameDue -> decode EOF -> upload waitingFrame` 循环，持续占用调度和 Trace 容量。
- replacement 前销毁旧 output 会使 Presentation反复重建 loading/首帧状态，放大主线程与平台 surface 抖动。
- 本轮不改变本地/缓存读取算法；dev.91 已加入的 `sourceRead/frameDecoded/frameUploaded/framePresented/playbackFrameDue` 继续用于后续大图和动画性能分析。

### 测试错误或缺口

- `native_texture_viewport_test` 把固定尺寸 Widget 直接作为 `MaterialApp.home`，根节点获得测试窗口 800×600 的 tight constraints；其 300×600 期望没有实际布局依据。已通过 `Center` 建立正确松约束 fixture，产品 geometry 不改。
- 既有测试只覆盖 output 从 upload window 退休后重入，未覆盖静态帧 timer、有限动画最后一帧和“旧 output 保留到 successor 成功上传”。
- 缺少 `PlaybackTimer` 对零时长保持 idle 的回归。

## Trace 证据

用户在 dev.91 上实际复现后提供的 Trace 共 1337 条有效事件：

- 6 次 `pageHostMounted`，只有 3 次 `firstFrameReady`。
- 3 次 `framePresented` 的 `durationMicros` 全部为 0。
- 这 3 个 output 随后各自产生一次 `playbackFrameDue`。
- 回切页面 8、7 时没有新的 `firstFrameReady`。
- 失败 identity 在 `depth=0` 下持续 `decodeStarted -> decoding -> ended`，UploadSession 反复 `waitingFrame`。
- Trace 中没有 `pageOutputReleased`，说明本次 output 不是由 dev.91 新修的 demand-detach/frame-budget 路径退休，而是在播放推进内部先被移除。

因此根因是 UploadSession 的零时长 timer 与非原子 successor 替换，而不是用户未等待、网络重下、Reader Widget 丢失或 ADR 0075 的 output-loss 回调未触发。

## 所有权清单

| 状态/资源/命令 | 正确所有者 | dev.92 处理 |
|---|---|---|
| encoded source、artifact、resume | downloads/sessions/storage | 不变 |
| cursor、动画元数据、FrameHolder | DecodeSession | 继续产生 next/ended，不持有 renderer output |
| renderer output、replacement、present claim | UploadSession | 保留旧 output，successor 上传成功后原子替换 |
| 播放 deadline、暂停、倍速 | UploadSession/PlaybackTimer | 零时长不启动；有限 EOF 清除等待 |
| demand 与 source revision 唤醒 | LiveCoordinator | 继续只调度，使用 `preparedDepth=0` 请求 successor |
| 页面 loading/首帧 UI | Reader Presentation | 只消费 PipelinePageOutputStream，不缓存旧帧 |
| stitched viewport 几何 | texture_bridge | 产品实现不变；测试提供真实父约束 |
| 诊断事件 | telemetry + App Debug 投影 | 新增 `playbackCompleted`，不成为播放状态来源 |

## 被否决方案清单

- 用 10ms timer 永久轮询所有零时长帧：静态图会不断 EOF。
- 到期时立即销毁 output：有限动画和慢 successor 会退回 loading。
- 在 Reader 保存 last good frame：越过 Pipeline output 所有权。
- 扩大 current/transition upload window 或永久 keepAlive：增加显存且没有修正 timer。
- 把测试期望直接改成 800×600 而不审查约束：会固化错误 fixture；本轮显式加入 `Center` 还原测试意图。
- 为通过 `artifact_test` 修改产品 collection 类型：错误仅在测试使用了不存在的 Stream API。

## 修改与删除

- 修改 PlaybackTimer、UploadSession、telemetry/debug Trace 和 owner-package tests。
- 修复 storage 与 texture_bridge 的两个测试 fixture。
- 新增 ADR 0076、dev.92 审计和静态所有权门禁。
- 未删除生产文件；未新增 Reader/App 缓存、兼容 facade 或第二播放实现。

## 验证与未验证

当前环境已通过 repository/Dart structure、dev.75–dev.92 所有权门禁、Android/Mihon/Venera/Reader/Pipeline/UI 契约、共享浏览器 Kotlin 提取编译、native header 和本地 libwebp 1.6.0 incremental/loop fixtures。

当前环境没有 Flutter、Dart、Gradle、Android SDK 和 Cargo，无法执行 analyzer、Dart/Flutter tests、APK/kernel、Gradle/Rust 或真机复验。设备上应验证：静态图不再出现 `durationMicros=0` 后的 `playbackFrameDue`；动画到期后旧帧保持到下一次 `frameUploaded`；有限动画最终出现 `playbackCompleted.outputRetained=true`，且回切产生新的可呈现帧而非持续 EOF。
