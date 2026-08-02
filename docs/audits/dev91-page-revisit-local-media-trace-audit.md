# dev.91 页面重入与本地媒体 Trace 审计

## 问题清单

### 编译错误

- 新增回归测试最初使用不存在的 `PageRole.preDecode`；已改用真实的 `PageRole.near`，避免在无 Dart SDK 环境中遗漏 API 闭包。
- `frameUploaded` 新增耗时字段时，计时变量必须跨 try 块保留；已使用明确的 `late final int uploadMicros` 并在成功路径赋值。

### 产品错误

- 已加载页面离开 current/transition 后 output 被释放；由于 decode demand 仍在预解码窗口，DecodeSession 不 detach，空 FrameHolder 对应的 cursor 停在 EOF。回页后重复 `decoding -> ended`，UploadSession 永久 `waitingFrame`。
- frame budget 主动回收 output 使用另一条路径，若不共用重置逻辑，同样可能留下 consumed frame + EOF cursor。

### 性能问题

- 旧 Trace 只能看到大粒度 artifact/source 和帧状态，无法区分本地 SAF 分块读取、缓存恢复、解码、上传、呈现和动画调度中哪一段耗时。
- 高频逐 chunk 日志会放大诊断成本；本轮只在一个 `sourceRead` 事件中聚合块数、最小/最大块、首块时间、总时间和最大块间停顿。

### 测试错误或缺口

- 既有 DecodeSession detach 测试只覆盖 decode demand 本身离开；未覆盖 upload output 先离开、decode demand 仍保留的真实策略组合。
- 缺少 frame budget output retirement 与 decoder re-prime 的同一所有权门禁。
- 缺少 source/cache read trace、upload timing 和 playback lateness 字段的回归。

## Trace 证据

用户提供的 2094 条事件中：

- 共 14 次 `pageHostMounted`，只有 7 次 `firstFrameReady`。
- 第一 Reader 会话中页面 0、1、2 首次进入均完成首帧；返回页面 2、1、0 后均以 `firstFrameReady=false` 销毁。
- 第二会话页面 0–3 首次完成首帧；页面 4–6 随后长时间挂载但没有首帧。
- 失败阶段多个 identity 在 `depth=0` 下反复产生 `decodeState=decoding` 后立即 `decodeState=ended`，并出现 `uploadState=waitingFrame`，没有新的 `frameDecoded`。

这支持“已消费 cursor 未重建”，而不是网络重新下载失败或 Reader 单纯丢失 Widget 状态。

## 所有权清单

| 状态/资源/命令 | 当前正确所有者 | 本轮处理 |
|---|---|---|
| encoded source、artifact、resume | downloads/sessions/storage | 不变；Trace 只读投影 |
| decoded cursor 与 FrameHolder | DecodeSession | 新增空 holder 时的 output-loss re-prime |
| renderer output、present claim、播放 timer | UploadSession | 统一 demand detach 与 budget trim 的回收通知 |
| demand 与 follow-up 调度 | LiveCoordinator | 仅在 retained decode 被重置时唤醒 |
| frame budget | FrameBudgeter | 继续只决定裁剪；UploadSession 执行原子回收 |
| 页面 loading/首帧 | Reader Presentation | 只消费 PipelinePageOutputStream，不缓存资源 |
| 本地/缓存读取诊断 | ArtifactCacheTransport / PipelineReaderSession | 聚合 trace，不建立新 transport/cache |
| debug 展示 | apps/app DebugTraceLog | 只投影已有事件，可合并显示但 raw trace 保留 |

## 被否决方案清单

- 为回页保留所有 texture：显存无界并违反 current/transition 上传边界。
- 在 Reader `State` 或页面 Widget 中保存 bytes/image：形成竞争缓存和错误生命周期。
- 把已加载页面加入永久 keep：把产品错误转为内存增长。
- 每次切页销毁并重建所有 DownloadSession：破坏稳定 identity、resume 和 artifact 复用。
- 关闭预下载、缩小窗口或降低并发：掩盖错误且未经实验批准。
- 每 256 KiB chunk 单独写 raw Trace：高频诊断反过来影响性能；改用聚合字段。

## 修改与删除

- 未删除生产文件。
- 将 output-loss decoder 重置从 LiveCoordinator 直接跨 registry 操作迁入 UploadSession 与 DecodeSession 的既有依赖边界。
- 新增 dev.91 静态门禁和 owner package 回归，不在 App 重复 sessions 算法测试。

## 未验证项

当前环境已通过 repository/Dart structure、dev.75–dev.91、Android/Mihon/Venera/Reader/Pipeline/UI 契约、共享浏览器 Kotlin 编译、native header 与本地 libwebp 1.6.0 fixtures；但没有 Flutter/Dart/Gradle/Android SDK/Cargo，无法执行 analyzer、Dart/Flutter tests、APK/kernel、Rust 或真机复验。需在设备上重新导出 Trace，确认 `pageOutputReleased.decodeRestarted=true` 后出现新的 `frameDecoded/frameUploaded/firstFrameReady`，并比较本地大图的 `sourceRead`、`decodeMicros`、`uploadMicros`、`presentMicros` 与 `lateByMicros`。
