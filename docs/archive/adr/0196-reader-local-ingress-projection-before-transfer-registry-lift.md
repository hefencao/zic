# ADR 0196：在提升物理 Transfer Registry 前拆出 Reader-local Ingress Projection

- Status: Accepted
- Date: 2026-08-11
- Version: 0.31.0-dev.215

## 背景

dev.214 已把“谁需要图片”从单一 demand bool 改成 scoped claim，但 `DownloadSession` 仍直接持有
由当前 Reader media runtime 创建的唯一 native `Ingress`，`DecodeSession` 通过
`download.ingress`取得 encoded source。这样即使 claim 已可多消费者，也不能安全让两个 Reader
共享同一 physical session：它们会错误共享 native source/cursor 生命周期。

另一方面，artifact、writer、validators、resume prefix、content kind 属于物理图片传输；native
`Ingress`、source listener、decode/upload 则属于具体 Reader consumer。两者必须先拆开，才能在
后续把 network task/retry/registry 提升到 composition owner，而不把 Reader runtime 一起全局化。

## 决策

1. `DownloadSession` 不再构造、持有或 dispose 唯一 native `Ingress`。
2. 新增 `DownloadIngressProjection`：一个 projection 只拥有一个 consumer 的 native `Ingress`
   与 source listeners；同一 physical session 可附着多个 projection。
3. 新增 Reader-local `DownloadIngressProjectionRegistry`，其 `SourcePool` 仍由
   `PipelineReaderSession` 生命周期拥有；`DecodeSession` 显式接收本 Reader projection，不再通过
   physical download 反向取得 native source。
4. physical `DownloadSession` 仍负责 artifact/writer/resume/content-kind，并把 append/reset/seal/
   expected-length 事件 fan-out 到已附着 projections。
5. 普通 `attachIngressProjection()` 只允许 committed length 为 0 的创建阶段。已经存在 committed
   prefix 的 late consumer 必须使用 `attachSynchronizedIngressProjection()`。
6. late join 回放期间 projection 不进入 live fan-out。session 使用 projection revision + epoch +
   committed length + total length + sealed state 检验回放边界；若回放期间 append/reset/seal/bind
   开始则重放。最终状态检查和 map insertion 之间没有 `await`，避免 writer 在边界间插入新 chunk。
   physical owner仍必须把restore/promotion等生命周期迁移与新consumer join串行化；该协议重点允许active writer append期间安全追平。
7. dev.215 仍不提升 `DownloadRegistry`、network task、retry 或 terminal failure owner；这些继续由
   Reader-local `PipelineReaderSession/LiveCoordinator` 持有，下一阶段再迁移。

## 当前所有权

```text
Physical DownloadSession
  ├─ artifact / writer / run / validators / resume prefix
  ├─ content kind / physical transfer snapshot
  └─ projection fan-out
       ├─ Reader A DownloadIngressProjection -> native Ingress -> Decode/Upload A
       └─ Reader B DownloadIngressProjection -> native Ingress -> Decode/Upload B

PipelineReaderSession (dev.215 production)
  ├─ Reader-local DownloadRegistry / LiveCoordinator    [下一阶段提升]
  ├─ Reader-local DownloadIngressProjectionRegistry
  ├─ Reader-local DecodeRegistry / UploadRegistry
  └─ presentation state
```

生产代码当前仍是一 Reader 一 physical registry，所以第二个 projection 主要建立并验证下一阶段所需
的 ownership seam；不得据此宣称 cross-Reader active transfer 已在 production composition 启用。

## 后果

正面：physical session 已不依赖单一 Reader native source；decode/upload 没有因下载共享准备而被
全局化；late committed prefix 有明确同步加入协议。

未完成：`LiveCoordinator` 仍是 network/retry owner；artifact workspace仍来自 Reader-local
registry；chapter/whole-comic仍创建自己的 physical sessions；verified equivalence尚未前移成
TransferKey-before-acquire。因此不能删除 dev.205–213 的 durable partial/handoff/takeover兼容路径。
