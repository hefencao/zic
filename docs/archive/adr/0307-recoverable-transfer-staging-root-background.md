# ADR 0307：Recoverable transfer staging 与根返回后台化

状态：Accepted

## 背景

真机样本中，某 WebP 页面在旧进程里已经由 decoder 证明可播放，hot physical session 也已经累计数 MiB 连续 prefix；用户随后从 Android 任务界面划掉 App。下一次进入同页时却出现 `physical-local-prepare -> local-hydration-miss, committedLength=0`，只能重新等待 origin。源码确认 fresh `CompositionDownloadTransferRuntime` 过去使用 `EphemeralCacheWorkspace.readerSession()`，其目录包含 `pid + microsecond nonce`。任务移除若没有执行 Dart `dispose()`，旧 bytes 可能仍留在 App 私有 cache，但 replacement runtime 不再访问旧路径。

此前 ADR 0258 试图通过 `paused/detached -> durable partial checkpoint` 缩小该窗口；这把普通后台生命周期与正文持久化 I/O 绑定，并且仍不能覆盖系统不给 Dart 完成 checkpoint 的任务移除/进程终止。与此同时，Home 二次返回一度把 service close、partial checkpoint、偏好 flush、FlutterEngine detach 与 task finish 串成同步退出 barrier，导致用户返回动作被清理工作阻塞。产品语义实际是把 App 切到后台，而不是主动 shutdown。

## 决策

1. production persistent composition 的 fresh mutable partial 使用 App 私有的 recoverable transfer staging root。该 root 由稳定的 App support identity 派生，不包含 process pid 或 runtime nonce；用户选择的 SAF/POSIX 下载目录不参与该 staging identity。
2. 同一 `DownloadId` 继续由 `CacheLayout` 生成 deterministic artifact path。replacement runtime 在 network admission 前先按既有 `DownloadSession.restore()` 恢复 staging 中实际存在的连续 `0..N` prefix；随后 Reader ingress / decoder 直接消费现有 encoded bytes。
3. partial 只声明连续 encoded-byte authority，不声明“已可播放”。decoder 自己判断现有 N bytes 能否出首帧/多少帧并可报告 `needMoreData`；这些 decode 事实不得反向成为 partial persistence、checkpoint、flow park 或 network admission 条件。transport 是否继续增长只由既有 demand / NetLane / resume policy 决定。
4. 普通 App `paused/detached` 与 Home 根返回不触发 hot-partial durable/SAF copy。`checkpointPartials()` 作为显式 runtime safety capability 保留，供真正 owner teardown、目录迁移、retention pressure 等已有边界调用；它不得重新绑定到普通后台化。
5. Home 根路由第一次返回仍给出 2 秒二次确认；确认后的第二次返回只请求 Android `moveTaskToBack(true)`，保持当前 Activity、FlutterEngine、Dart services 与 transfer owners 原位存活，不等待 checkpoint、service close、偏好 flush 或 durable I/O，也不主动 `finishAndRemoveTask()`。
6. graceful runtime dispose 仍先按既有 handoff/owner teardown 收口，再删除 recoverable staging workspace；任务移除/进程终止若没执行 dispose，则 staging 留给下一 runtime 接管。replacement runtime 不需要 durable partial store entry 才能恢复该 prefix。
7. stable staging 是可恢复 cache/staging，不是第二 durable cache authority。系统显式清缓存、结构损坏、owner mismatch 或真正 cleanup 仍可使其消失；完整 durable artifact、显式下载和 SAF mirror 的 authority 保持原设计。

## 保持不变

- canonical 3/7 DownloadDemand、decode 2/1、Upload/transition 水位、FrameBudget、NetLane normal/current 并发、6 秒 body-read watchdog均不改变。
- `PartialDownloadHandoff`、persistent indexed partial、POSIX exact adoption 与 required durable completion继续存在；本 ADR 只移除普通 background 对 durable checkpoint 的依赖。
- Reader/UI仍不得直接持有或写 transfer partial；recoverable staging 的 ownership 仍在 storage + composition transfer runtime。

## 否决方案

- “partial 还不能播放就强制继续下载直到 playable”：否决。它把 decoder 结果变成第二套 network eligibility，并错误扩大 opportunistic partial 的传输义务。
- “首次 playable 后持续复制 durable prefix”：否决。playability不是 storage authority，且在 SAF 配置下会把额外 provider I/O 拉进 hot path。
- “把 fresh partial 直接同步写用户 SAF 根”：否决。hot staging 与下载目录是不同资源边界，SAF provider 串行 I/O 不应成为每个 network append 的前置条件。
- “根返回先 await 全部 cleanup 再 finish App”：否决。导航动作不得被 durable/service teardown 锁住，且产品目标只是后台化。
