# dev.97 后续交接

唯一后续基线：`zic_v0.31.0-dev.97_midpoint-playback-trace-filter.zip`。不得再以 dev.96 或更早 ZIP、补丁树或记忆源码覆盖。

- 三清单审计：`docs/audits/dev97-page-handoff-trace-audit.md`
- 验证明细：`docs/audits/dev97-validation-results.md`
- 架构决策：`docs/adr/0081-midpoint-playback-handoff-and-diagnostic-trace.md`

## 已完成

1. `ReaderView` 在 PageView 跨 50% 时保留 fractional observation；新 stable/current 接管播放，旧页暂停但继续作为 transition 保有既有 output。
2. `ViewportResolver` 默认 0.5，不再存在 40%–60% 双冻结；精确 50% 在 `onPageChanged` 后由新 stable/current 接管。
3. Pipeline runtime 在 late UploadSession snapshot 后重投影 ReaderBinding 已保存的 viewport，避免新页偶发不启动、回切才播放。
4. Debug Trace 高频 frame/decode/upload/scroll 事件使用固定首事件窗口摘要；错误与关键生命周期事件不参与合并，容量淘汰显式计数；长 identity 使用稳定 hash+长度。
5. 三处 Dart capability 调用改为显式局部 cast；libwebp v1.6.0 patch 改为 CRLF/LF 无关、幂等且拒绝半应用的函数锚点 transformer。
6. 7/3、页面 2/1、current/transition、5/3/2、双常驻 decode isolate、libwebp 帧内单线程和 successor 2/1 均未改变。

## 后续设备验证

1. 连续往返滑动 Animated WebP：每次跨 50% 后旧页停止推进、新页立即推进；不得黑屏或重建同一 texture。
2. midpoint 附近不得再出现 outgoing page 的 `pageOutputReleased(reason=demand-detached)`；真正离开 current/transition window 后允许释放。
3. 对比同等播放时长的诊断 Trace 大小、`coalescedCount` 和 min/max timing，并确认错误与 output retirement 仍逐条存在。
4. 有完整工具链时依序运行 `flutter analyze`、受影响 package tests、App tests、Android debug/release、Rust/libwebp 检查和真机验证。
5. 不得以 Reader 私有纹理缓存、扩大 upload window、固定延迟、缩小 7/3 或 2/1、降低 lane 并发替代生命周期修复。
