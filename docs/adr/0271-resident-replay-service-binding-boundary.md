# ADR 0271：resident replay service / physical capability 绑定边界

状态：Accepted（dev.292）

## 背景

dev.291 把 source metadata / prefix 读取收回 physical DownloadSession，但本地 Dart 编译暴露两处同源签名错误：`PipelinePageStream`把 `(DownloadSession, endExclusive)` service 传给只接受 `(endExclusive)` 的参数；`DownloadSession.readSourcePrefix()`收到已绑定 callback 后又错误调用 `replay(this, end)`。这说明 resident replay 的“跨 owner service”和“绑定到具体 physical generation 的 capability”没有被类型边界区分清楚。

进一步审计发现 `PipelineReaderSession`仍自行实现 artifact-cache / local-source resident replay backend 选择；这与 dev.291 “Pipeline 不选择 storage/body backend” 的 ownership 目标冲突，并与 composition transfer runtime / owner 的 replay 能力重复。

## 决策

1. sessions 只保留两种明确 ABI：`DownloadResidentReplaySource(DownloadSession, endExclusive)` 是跨 composition/runtime/registry 的未绑定 service；`DownloadResidentReplayChunks(endExclusive)` 是已经绑定到一个 concrete physical generation 的 capability。
2. `DownloadSession`方法只接受 bound `DownloadResidentReplayChunks`，不得再次把 `this` 作为 callback 参数；registry/page-stream 必须在当前 concrete session 被解析后进行一次绑定。
3. resident body backend 选择统一归 `CompositionDownloadTransferRuntime`：优先 composition `ArtifactCacheManager`，cache miss 时仅允许既有可重开 immutable local source fallback；读取继续服从共享 `ArtifactCacheReadScheduler`。Pipeline 只提供动态 read priority，不再直接 lookup cache、open resident source 或实现 replay stream。
4. `DownloadIngressProjectionRegistry`、`PromotedArtifactCacheHandoff`、`PipelinePageStream`统一复用 sessions 中的 canonical replay typedef，不再各自声明同形 callback typedef。
5. dev.291 generation-local 64-byte metadata prefix、sourceCanvas authority、Reader previous3/next7、decode previous1/next2、NetLane、texture/retention策略保持不变。

## 可证伪判据

本地 Dart/Flutter 编译必须不再出现 resident replay callback arity/type mismatch。设备验证仍沿 dev.291：artifact-cache resident imminent page 应命中 `physical-ingress-source-canvas`；若该事实链闭合但尺度仍异常，停止继续修改 replay/预解码并转查 Sliver/item extent/output projection。
