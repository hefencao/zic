# dev.292 Resident replay binding / ownership audit

## 触发

用户本地编译 dev.291 报两处同源错误：

- `PipelinePageStream.forDownload(... residentReplaySource: _openResidentReplaySource)`：`Future<Stream<List<int>>> Function(DownloadSession,int)` 无法赋给 `Function(int)`；
- `DownloadSession.readSourcePrefix()`：已声明 callback 只接受一个 `endExclusive`，实现却调用 `replay(this, end)`。

用户要求继续审查代码边界并解耦收口，而不是只修改参数个数。

## 根因

resident replay 实际存在两个层次，但 dev.291 使用了容易混淆的重复 typedef / 命名：跨 runtime 的 service 必须显式拿 concrete `DownloadSession`，进入 session 后的 callback 已经绑定该 generation，只应再接收长度。PipelinePageStream 既动态 rebind physical session，又把 service 字段声明成 bound callback；DownloadSession 则反向把 bound callback 当 service 调用。

同时 `PipelineReaderSession`仍包含完整 `_openResidentReplaySource()`、cache lookup、local immutable source open、bounded/scheduled replay，实现上继续选择 body backend，和 composition transfer owner 重复。

## dev.292 收口

- canonical ABI 收到 sessions：`DownloadResidentReplaySource(session,end)` + `DownloadResidentReplayChunks(end)`；删除 registry/downloads 中重复同形 typedef。
- `PipelinePageStream`保留 unbound service，因为其 concrete session 可换代；每次读取时按当前 session 绑定为 `(end) => source(session,end)` 后交给 `DownloadSession`。
- `DownloadSession.readSourcePrefix()`只调用 bound `replay(end)`；late ingress synchronized replay同样只接受 bound chunks capability。
- backend 选择提升到 `CompositionDownloadTransferRuntime.residentReplaySource()`；PipelineReaderSession 删除 private resident cache/local-source replay实现，只注入动态 artifact-read priority。
- composition runtime 保留 dev.221 的语义：cache优先、immutable local fallback、共享 ArtifactCacheReadScheduler；普通 remote source不会借 resident replay 绕过既有 network authority。

## 未扩大范围

没有修改 dev.291 source metadata prefix/sourceCanvas 语义，没有扩大 decode/prefetch/window/cache，也没有继续改 Reader vertical geometry。当前环境仍无 Dart/Flutter SDK，真实编译结果必须以用户本地为准。
