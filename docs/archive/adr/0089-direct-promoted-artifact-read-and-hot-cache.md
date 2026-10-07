# ADR 0089：直接读取 promoted artifact 与 composition encoded-byte 热缓存

**状态：Provisional**

## 问题

persistent cache 命中时，旧路径先调用 `DownloadSession.restore()`。persistent service 的 registry 没有绑定 ingress，因此 `_rebuildIngress()` 会立即返回；但 restore 仍重复执行 artifact metadata restore、prefix sniff、SQLite cache sync 和状态通知。随后 Reader 再通过 1 MiB async stream 读取完整文件；快速退出并重进时，同一页面会重复读盘。

VibeVenera 的本地文件和磁盘缓存路径对大于 1 MiB 的文件直接在 isolate 中执行整文件读取，并由有界 encoded-byte cache 复用；不会先重建一套下载会话。

## 决策

1. persistent cache 的 `readPage`、`readArtifact`、`openArtifactStream` 只恢复 `Artifact` 元数据，不调用与只读 cache hit 无关的完整 `DownloadSession.restore()` 状态链。
2. `ArtifactCacheStreamEntry` 可暴露只读 `readAll` capability。current/transition 才能使用此快速路径；background 继续使用 dev.104 的 1 MiB chunk quantum。
3. 大于 1 MiB 的本地 promoted file 使用 `Isolate.run(() => File(path).readAsBytesSync())`。
4. `PipelineReaderSessionFactory` 拥有一个跨 Reader session 共享的 `PromotedArtifactByteCache`：默认 4 项、96 MiB、LRU、按 identity+length 校验，并合并同 identity 的并发读取。
5. 快速整文件读取失败时回退同一 promoted artifact stream，不回退原始网络或 `content://` 源。
6. 缓存只保存 immutable encoded bytes，不拥有 demand、download、decode、upload、texture 或播放状态。

## 边界

- 不改变下载 7/3、预解码 2/1、upload current/transition、lane 5/3/2。
- background 预取不填充 encoded-byte 热缓存。
- 该优化在设备复验前不得写成已验证性能结论。

## 解除 Provisional 条件

同一设备和 fixture 的 dev.105 Trace 证明：promoted cache open 不再包含多余的 session restore/prefix/index 状态链；current/transition 出现 `read-all`，快速重进出现 `memory-hit`；first-chunk、完整 stream 和 Reader 重进耗时没有退化。
