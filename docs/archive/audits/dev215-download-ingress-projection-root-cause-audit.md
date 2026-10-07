# dev.215 Download Ingress Projection 根因审计

## 基线与问题

唯一源码基线：`zic_v0.31.0-dev.214_image-transfer-consumer-claims.zip`。dev.214 已证明 scoped
claim 能表达多 consumer priority/cancel，但 physical `DownloadSession` 仍包含一个 Reader-native
`Ingress`，`DecodeSession`直接读 `download.ingress`。因此直接共享 registry 会把 decode source
生命周期错误地绑定到创建 physical session 的 Reader。

## 实际 owner 重新分类

应继续属于 physical transfer：`Artifact`、writer/run lease、validators、network resume baseline、
committed prefix、content kind、seal/promotion状态。

应属于 Reader consumer：native `Ingress`、source listeners、cursor/decode、upload、presentation。

仍待迁移到 physical transfer owner：`LiveCoordinator` 的 network task key、retry round/pending、
terminal failure、deferred catch-up，以及 Reader-local `DownloadRegistry`/artifact root。

## dev.215 最小安全切面

- `DownloadRegistry` 删除 `SourcePool` 注入，不再为 physical session创建 native ingress。
- Reader composition 新建 `DownloadIngressProjectionRegistry`；session创建时先附着本 Reader
  projection，再由 Decode/Live source listener消费它。
- `DownloadSession` 对所有已附着 projection fan-out committed/reset/seal；page kind直接取
  physical snapshot的 `contentKind`。
- late projection 不能“attach空Ingress后再异步回放”，否则 replay 与 writer append会产生 offset
  交错。本轮改为 projection先离线回放；任何 physical mutation推进 revision并使本轮回放失效；
  只有稳定边界才无 await 插入 live fan-out。
- Reader shutdown先 detach/dispose projection与 SourcePool，再关闭 media runtime；physical
  DownloadSession不再误关闭 Reader-native source。

## 为什么仍不提升 physical registry

Ingress 阻塞已移除，但 `LiveCoordinator` 仍持有真实 network/retry/terminal 状态，而且当前
`CacheLayout`仍由 Reader session创建。此时提升 `DownloadRegistry` 仍会留下 A/B coordinator
争同一个 writer/run 的双 owner。因此下一阶段应先把 physical scheduler/retry owner与稳定 transfer
workspace提升到 composition，再让两个 Reader acquire 同一 exact TransferKey。

## dev.205–214 补偿机制分类

- verified artifact reuse / persisted page mapping / equivalence registry：保留；后续 TransferKey proof输入。
- durable partial copy：保留，仍负责冷启动/进程边界。
- session partial handoff、retained session、equivalent-full promotion takeover：兼容层；physical hot
  transfer共享覆盖后再逐项删除，不能现在先删。
- artifact cache owner：保持不变，不因 projection拆分建立第二 durable cache。
- Reader-local `DownloadRegistry`：仍为临时 owner，dev.215 不假装完成其提升。

## 下一阶段进入条件

1. composition-scope physical transfer registry拥有 exact physical transfer；
2. network task/retry/terminal failure只存在一个 physical owner；
3. Reader只 acquire/release claim + ingress projection；
4. physical artifact/workspace不依赖某个 Reader route临时 root；
5. exact DownloadId sharing验证后，再把强证据 version equivalence前移到 TransferKey acquire前；
6. chapter/whole-comic/prefetch随后改成同一 transfer owner上的 demand aggregation。
