# zic Implementation Plan

本文件只列未完成工作。

## P0：Transition 首帧与切页设备闭环

- 验证拖动建立 transition 后，即使 current holder 为 0，目标页也先产生独立首帧。
- 确认目标页网络不等待 current source sealed、完整下载或 holder depth。
- 验证 transition 首帧后 current 基础水位先于 transition 深水位，且反向拖动不重建同一 identity。

## P0：远程 Animated WebP 连续性

- 对比 transport chunk、64 KiB session append、source revision、decode batch、holder depth、deadline 和 present cadence。
- 若 current 仍断粮，只在 NetLane ranking、重复 request/source、partial wake、decode producer 或 upload deadline 内定位；不得恢复 FlowGate/startup-buffer、缩小 7/3 或降低速度。

## P0：后台重入生命周期

- 验证两分钟内同章重入命中 `readerSessionReused`，不重新创建整组 Download/Source/Decode session。
- 确认 used texture 仍重新创建，idle resource retention 不跨 Reader 复用 SurfaceProducer。
- 验证 TTL、source revision变化和第二章节淘汰后的完整 dispose。

## P0：Flutter/Android 工具链闭环

- 运行 `flutter analyze`、受影响 package owner tests、App tests和 Android debug/release build。
- 运行 Rust/Android target 与 JNI symbol验证，确认 APK 中 native build identity正确。

## P1：漫画源与详情预览设备闭环

- 验证漫画源分类切换会选择分类内首个来源、重置第一页，并确认上一页/下一页不重复或跳过结果。
- 验证 Mihon 已安装和仓库语言分类在真实 index.pb、运行时 discovery metadata 上稳定，未知语言不被误分。
- 在窄屏/宽屏及极端横纵比预览上确认折叠第一行与展开第一行尺寸一致、面积比不超过 1.2、整体不超过屏幕高度 80%。

## P1：首页与缓存身份

- 设备验证本轮 primary projection 到第一封面请求的时序，并确认 native prewarm、整本
  队列 restore、外部插件 activation 不再位于 Home 首帧关键路径。
- 设备验证首页多封面快慢混合时的渐进显示：确认 `homeCoverFirstFrame` 按封面独立推进，
  不被 durable response 串行写入或其它慢封面形成全局等待。
- 验证封面 URL/token 变化仍命中 stable cover key，verified artifact alias不会污染无证据页面。
- 设备验证已有 raw durable cover hit 时的 source-independent 分流：首屏不触发插件资源
  请求；同时确认已持久化 canonical alias 的同源 raw ID 在插件未激活时只显示一张书架卡片，
  且未访问书架页不创建额外 cover loader。
