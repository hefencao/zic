# dev.226 Phase E compensation evidence audit

## 输入

- 唯一源码基线：`zic_v0.31.0-dev.225_verified-transfer-alias-before-acquire.zip`。
- 用户真机 Trace：`zic-debug-trace-2026-08-11T15-01-20.jsonl`。
- 重点源码：`CompositionDownloadTransferRuntime`、`DownloadTransferOwner`、`DownloadRegistry`、`LiveCoordinator`、partial/artifact durable handoff。

## 真机事实

本轮对 4253 条 Trace event 做分类：

- `downloadStarted=28`，`downloadPreempted=13`；
- `taskFailed=0`、`writerRejected=0`，未发现 `sessionBusy/writerBusy`；
- 25 个 `pageHostDisposed` 均为 `firstFrameReady=true`；
- `verified-equivalent-promotion-takeover=0`；
- `session-partial-handoff`：12 次，全部 `stored`；
- `session-artifact-handoff`：48 次，其中 5 次 `stored`、43 次 `skip-existing`；
- version mapping/equivalence restoration 与 durable partial reuse 仍有实际事件。

## Ownership 重新分类

### 可立即删除

- `LiveCoordinator.refreshDownloadForLocalArtifact()`：生产无调用者，只是旧 Reader-local takeover 委托。
- `DownloadTransferConsumer.refreshForLocalArtifact()`：仅服务上述死委托。

### 继续兼容，但收紧作用域

- equivalent-full promotion takeover：只允许 composition owner 针对已经独立创建的 exact physical session；acquire-time alias 后的 identity 不再参与扫描。

### 新架构仍需要

- physical partial → `PartialDownloadStore`：最后 claim 消失/owner dispose 时的 cold persistence。
- promoted physical artifact → `ArtifactCacheManager`：immutable durable authority handoff；`skip-existing` 也是幂等持久化边界的一部分。
- verified equivalence registry/page mapping：继续作为 acquire-time proof 输入与 exact durable reuse 证据。

## 结论

Phase E 第一批删除应针对错误 owner 和死 delegation，而不是针对文件名/trace label。dev.226 通过明确 acquire alias 与 legacy takeover 的 trace 事件，为下一轮决定最终 compatibility path 是否可删除建立直接证据。
