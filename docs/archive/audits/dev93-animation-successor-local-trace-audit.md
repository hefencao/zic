# dev.93 动画 successor 与本地播放 Trace 审计

## 问题清单

### 编译/测试错误

- `upload_session_test` 的 `_CursorFactory` 只返回 FrameCursor，遗漏同一 cursor 的 LoopCursor 绑定，导致 AnimationInfo 始终未知，静态零时长用例错误进入 running。
- dev.93 当时把 0.5/0.5 定义为 overlap 且 dominant null；该历史判断已由 dev.97/ADR 0081 的新 stable/current midpoint 接管语义取代。
- LiveCoordinator 测试漏算最终 source seal 的独立 revision；实现 drain 4 次是正确行为。
- local_media_ui 测试读取未应用 FittedBox transform 的 RenderBox size，并假设 fitWidth 仍存在第二 FittedBox；均为旧 fixture。

### 产品错误

- 动画当前 output 被计入 `preparedDepth=1`，使 decoder 在当前帧显示期间不准备 successor。
- deadline 到达后才将 prepared depth 降为 0，decode/upload 与显示完全串行，放大播放卡顿。

### 性能问题

- Trace 中动画 duration 主要为 33/34 ms，decode 中位数约 124 ms；没有 successor overlap 时每帧必然停顿。
- native texture queue/upload 与 Dart `presentMicros` 差距较大，旧 Trace 无完整 MethodChannel round trip，无法区分 bridge/调度等待。
- origin `content://` 5.5–5.7 MB 文件约 8.6–8.7 秒，14–17 MB 文件在约 11.7 秒时仍未完成；旧桥每 256 KiB 都经过一次 MethodChannel。seekable descriptor 改为 direct-fd stream，不可 seek provider仍 fallback。部分远程图片失败保持独立后续项。

### 测试缺口

- 缺少“当前动画 output 可见时 holder 缓冲一个 successor，但 deadline 前不替换”的 owner test。
- texture telemetry 缺少 round-trip/bridge 字段门禁。

## Trace 摘要

用户提供的 2753 条事件中：`frameDecoded` 50 次、`frameUploaded` 86 次、`framePresented` 43 次、`playbackFrameDue` 29 次。动画帧 duration 主要为 33000/34000 微秒，decode 中位数约 124083 微秒；Presentation present 中位数约 105493 微秒，最大超过 1.3 秒。该证据支持将当前帧显示与 successor decode 重叠，并增加 texture bridge 分解；它不支持缩短预下载窗口或把远程下载失败归因于 decoder。

## 所有权清单

| 状态/资源 | 正确所有者 | dev.93 处理 |
|---|---|---|
| 当前 renderer output、deadline、replacement | UploadSession | 当前动画 output 不计 successor；deadline 后替换 |
| cursor、AnimationInfo、decoded successor | DecodeSession/FrameHolder | 使用现有 watermark 最多缓冲一帧 |
| due-frame 唤醒 | LiveCoordinator | 同时唤醒 upload/decode，不持有帧 |
| Android texture native queue/upload | texture bridge | 原字段保留 |
| MethodChannel 总往返诊断 | AndroidTexturePresenter | 新增 Stopwatch 投影，不参与决策 |
| Android document descriptor/close | local_media_bridge | native 持有，Dart 仅短期 direct-fd 读取；失败回退 chunk |
| 页面显示 | Reader Presentation | 继续只消费只读 surface |

## 被否决方案清单

- Reader last-frame cache、额外动画队列或第二 cursor。
- deadline 前提前替换 successor。
- 修改原始帧 duration 适配慢设备。
- 缩小 7/3、2/1 或降低 lane 并发掩盖竞争。
- 将未复现的远程下载失败混入本地播放修复。
- 把本地文件复制到 App 安装目录来规避 provider：增加副本与清理所有权。

## 验证与未验证

仓库结构、directive、dev.75–dev.93 门禁和 Android/Mihon/Venera/Reader/Pipeline/UI 契约应在最终包解压后复跑。当前环境无 Flutter/Dart/Gradle/Android SDK/Cargo，真实 package tests、analyzer、APK 与设备帧率仍需用户环境验证。