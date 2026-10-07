# dev.236 partial progress authority root-cause audit

## 问题清单

- 产品：用户观察到等价页面的 partial 进度条仍各自变化，和“physical partial 已共享”的预期不一致。
- 性能：03:34 Trace 仍有 19,782,164 `duplicatePrefixBytes`；其中 provider-validator mismatch 已正确变为 64 KiB overlap 206，剩余大块主要是真实 200 full-body catch-up，和本轮进度分裂不是同一根因。
- 稳定性：Trace 有 1 次 source 未 sealed 时的 `partial-source` decode failure，独立保留。
- 测试：既有 transfer progress 测试只覆盖单 exact session，没有覆盖 logical alias -> physical session 投影。

## Trace 证据

- 共 6148 条事件，15 次 `verified-transfer-acquire-alias` 全部 `joined-existing-physical`。
- current page 303 acquire 后直接从 existing physical owner 的 1,946,180 committed bytes继续；page 300直接从3,314,200 bytes继续。说明网络/partial owner并非各自从0开始。
- 6 次 `providerValidatorMismatch=true` 均进入 `validatorless-range-probe` 并以206返回，每次只付64 KiB overlap，dev.235 validator scope修复真实生效。
- 因而“进度条各自”的剩余解释必须位于progress projection，而不是重新否认physical partial共享。

## Ownership 清单

- committed prefix / writer / retry / total length：physical `DownloadSession`。
- logical exact -> physical alias：composition `DownloadRegistry` / transfer owner。
- current Reader transfer progress：`pipeline_runtime` 的 `PipelineTransferProgressPublisher`，事实源必须是resolved physical session snapshot。
- Reader：只消费只读 progress notifier，不拥有session、alias或缓存。
- Reader-local encoded ingress：`DownloadIngressProjectionRegistry`，一physical session一projection。

## 根因

旧 publisher 在 `observe(session)` 中只以 `session.id.key` 注册physical session；`select(currentDownload)`却保存logical exact `DownloadId.key`。acquire-time alias B -> A 后，logical B key 与physical A key不同，于是progress projection仍有一张独立exact-key索引表，无法稳定代表已共享的physical partial。

## 决策与拒绝方案

- 删除 exact-key progress session表，reconcile完成后直接选择`DownloadRegistry.find(currentDownload)`返回的physical session。
- 拒绝把physical committedLength复制进每个logical session：这会重新制造第二份state owner。
- 拒绝Reader侧建立alias-aware progress cache：Reader不能拥有physical事实。
- 拒绝late merge两个已存在physical session：dev.225/228/233已明确禁止。
- 拒绝为了进度问题修改NetLane/full-body admission或provider URI；Trace不支持把这两个问题合并。
