# ADR 0217：Shared physical transfer 的 active provider lease handoff

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.237

## 背景

04:17 真机 Trace 中，dev.236 已让 Reader progress 直接监听 resolved physical `DownloadSession`，但切换 Reader/session 后可见 committed progress 仍长时间不增长。Trace 显示该 physical session 的 `committedLength`确实没有增长：旧 provider 正在 full-body prefix catch-up 重读已经提交的旧前缀。新 current claim 到达后，NetLane task priority 会升到 1000，但 `_runDownload` 在 task 启动时捕获的 consumer/provider exact URI 不会变化，因此网络 attempt 继续绑定旧 Reader provider。

## 决策

1. physical `DownloadSession`、artifact、writer、committed prefix 继续是唯一 transfer authority；provider handoff 不建立第二 session，也不复制 partial。
2. active source provider 明确定义为 **task-scoped lease**，记录 task key、consumer scope、provider exact ID 与 claim sequence。
3. 当 active provider 对应 claim 已不存在时，lease 视为 orphaned；只要 physical session 仍有 demand，owner 必须取消旧 task，让同一 physical partial 在旧 writer 真正退出后由当前 preferred claim 重开。
4. active claim仍存在时，只有另一个 preferred claim 的 priority **严格更高**才允许 handoff；equal-priority 不切 provider，避免 route/prefetch revision 抖动制造网络 churn。
5. queued task 尚未取得 active provider lease；它在真正开始 `_runDownload` 时读取当时的 preferred claim，因此不需要额外重排 provider。
6. visible progress 继续只反映 `DownloadSession.committedLength`。full-body catch-up 消耗的 duplicate prefix 不是新 authority bytes，禁止为了“看起来在动”而计入进度。

## 非目标

- 不修改 full-body catch-up admission 阈值或 NetLane restart-cost policy。
- 不把 provider lease 上移到 Reader/Pipeline。
- 不 late-merge 两个已经存在的 physical session。
- 不改变 provider-scoped validator、cold partial 或 durable artifact identity。
- 不用轮询或 synthetic progress 掩盖冗余下载。
