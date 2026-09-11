# ADR 0312: Reader re-entry retention 保留两个 media-empty 最近会话

- Status: Accepted
- Date: 2026-09-11
- Refines: ADR 0305 的 idle session 数量上限；不改变其 media release boundary

## Context

最新 `zic-debug-trace-2026-09-11T02-08-05.jsonl` 的尾部反复在两个已验证版本 Reader 之间切换。旧 retention pool 只能保留 1 个 idle session，因此 A/B 交替形成稳定 LRU thrash：除一次同-key快速回访外，连续创建 `pipeline-reader-7/8/9/10/11`。每次新建都重新建立整章 Reader control/session 状态、local ingress hydration、presentation prewarm 与首帧 native bootstrap。同期出现 11 次 `buildMicros >= 100ms`，最大 360.6ms；8 次 `outputReadyToPresentMicros >= 100ms`，最大 390.7ms；428页版本首帧多次约 1.0–1.18s。设备快速进退还把 native allocator 推到较高 working-set 水位。

ADR 0305 已要求 retained Reader 立即释放 UploadSession、DecodeSession、native cursor/canvas/frame 与 used texture。dev.216 又把 physical DownloadSession/transfer owner 提升到 composition。新增机械观测确认 retained event 后 `decodeSessions=0`、`uploadSessions=0`、`ingressProjections=0`、`streamingSources=0`。因此第二个 idle session 不再等价于第二份 native media working set。

## Decision

- retention pool 的 idle LRU 上限从 1 调整为 2；TTL 仍为 2 分钟。
- 两个 slot 只服务最近两个 exact Reader session key，不合并、不改写 version identity，也不成为 physical media authority。
- `retainReaderSession()` 继续先撤销 demand/projection，再释放全部 upload/decode/cursor/frame/texture 与 Reader-local ingress/source；只有满足 media-empty 边界的轻量 session 可进入 retention pool。
- 第三个不同 key 进入 idle pool 时仍立即按 LRU 淘汰最旧 session，并执行完整 `dispose()`。
- 不扩大 FrameBudget、texture idle pool、decode worker 数或 network/prefetch window。

## Evidence

修改后同设备进行 6 次两个版本交替：只创建 `pipeline-reader-1`(371页) 与 `pipeline-reader-2`(428页)，后 4 次全部 `readerSessionReused`。每次 retained trace 都为 `decode=0 / upload=0 / ingress=0 / streamingSources=0`。`build>=100ms` 从旧尾部 11 次降为 1 次（103.5ms），最大 presentation-ready wait 从 390.7ms 降至 128.5ms，首帧从旧多次 995–1185ms 收敛到 122–364ms。6次切换后 PSS 约259MB，而问题现场约320MB；两边均无 task/source terminal failure。
