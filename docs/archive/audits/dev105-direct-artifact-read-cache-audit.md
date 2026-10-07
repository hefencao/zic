# dev.105 promoted artifact 读取与缓存审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.104_startup-artifact-quantum-cursor-continuity.zip`
- 设备 Trace：`zic-debug-trace-2026-08-03T11-52-09.jsonl`
- 只读参考：VibeVenera `local_file_loader.dart`、`image_loader.dart`、`byte_cache.dart`

## Trace 观察

Trace 共 2379 个事件，其中 40 条 `sourceRead`，39 条来自 `artifact-cache-stream`。现有样本：

- cache open：p50 约 25 ms，p95 约 464 ms，最大约 803 ms；
- first chunk：p95 约 572 ms，最大约 1.45 s；
- 完整 stream：p50 约 1.00 s，p95 约 1.91 s，最大约 1.92 s；
- 17 个 artifact identity 在两个 Reader session 中重复读取。

`sourceRead.streamMicros` 不是纯磁盘读取时间：Trace 包装的是 response stream，包含下游 DownloadSession 逐 chunk 消费、临时 artifact 写入和 ingress backpressure。71 条 `bytesCommitted` 样本中的 artifact write p50 约 21 ms、p95 约 32 ms、最大约 124 ms。dev.105 因此新增独立的 `artifactMaterializeMicros`，下一份 Trace 才能把真实整文件读盘和 session-copy 分开。

这些数字描述 dev.104 设备样本，不是 dev.105 验证结果。

## 源码根因

`PersistentChapterDownloadService.openArtifactStream()` 先取得 `DownloadSession` 并调用 `session.restore()`。该 persistent registry 没有绑定 ingress，所以 `_rebuildIngress(sealed: true)` 实际立即返回；旧路径的多余成本来自 artifact metadata restore、prefix sniff、SQLite cache sync 和状态通知。之后 Reader 仍通过 1 MiB async stream 完整读取 promoted file；快速重进会再次读同一文件。

## VibeVenera 对照

- 本地文件和已验证磁盘缓存大于 1 MiB 时，使用 isolate 内 `readAsBytesSync()`；
- decoded image cache 包含有界 L2 encoded-byte cache；
- cache hit 不先创建或恢复一套下载会话。

本轮只采用“直接大文件读取”和“有界 encoded-byte L2”两个低耦合机制，没有复制 VibeVenera 的 UI、网络或 decode ownership。

## 修改

- persistent read path 绕过 `DownloadSession.restore()`，只恢复 promoted artifact 元数据；
- foreground promoted artifact 可整文件读取，background 保留 chunk quantum；
- composition 共享 4 项/96 MiB encoded-byte LRU，并合并并发读取；
- Reader 重进优先命中 shared encoded bytes；
- 快速路径失败回退 promoted artifact stream；
- Trace 新增 read mode、memory hit/join、materialize 和 hot-cache 容量字段。

## 风险

- 整文件读取会增加短期 encoded-byte 常驻；由 4 项和 96 MiB 双限制约束；
- 首次 current 需要先完成本地整文件读取，再向 session ingress 快速分块；设备上是否优于直接 chunk stream 尚待验证；
- identity 或长度变化会拒绝复用旧缓存。
