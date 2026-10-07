# dev.134 Reader 资源会话冗余路径审计

## 输入证据

设备 Trace：`zic-debug-trace-2026-08-05T02-47-39.jsonl`。

- 1389 个事件，创建并完整销毁 5 个 `PipelineReaderSession`。
- 共启动 47 个下载任务；同章每次重新进入 Reader 都重新创建约 9 个下载会话。
- current 页面 4 次命中 `artifact-byte-cache`，缓存查询仅需几十微秒，但 18,319,682 字节仍被复制进新 DownloadSession/native source。
- 四次 `memory-direct` ingress 分别耗时约 701、704、710、2865 ms。
- 长后台后 mount-to-first-frame 为 3,491,504 µs，其中主要成本是 2,865,274 µs 的重复 native ingress。
- native decode 中位耗时约 56 ms，不能支持“CPU 解码是主因”的判断。
- `workerPlacementStatus=3` 仅说明 affinity 修改未生效；本轮删除该无证据路径。
- dev.133 单 blit 后 platform present 最大值约 249 ms，较旧 Trace 的约 1.54 s 已收敛，因此保留单 blit，不恢复 background channel、双 lane 或 front-of-queue。

## 冗余路径

修复前：

```text
Reader Host dispose
→ PipelineReaderSession.dispose
→ DownloadRegistry / SourcePool / DecodeRegistry / media runtime 全部销毁
→ 相同章节重新进入
→ 新建全部资源会话
→ ArtifactCacheManager 命中完整字节
→ 仍复制到新的 DownloadSession/native EncodedSource
→ artifact promotion / handoff
→ 才能继续 decode
```

缓存并没有消除资源重建，只把 `content://` 读取替换成了一次大内存复制。

## 所有权结论

- Reader/Widget：只拥有可见 binding、page projection 和 presentation demand。
- `PipelineReaderSession`：拥有章节级 DownloadSession、native source、DecodeSession、artifact handoff 和 media runtime。
- 已使用 Android texture：随 presentation output 销毁，不进入 retained resource lease。
- chapter resource session：退出 Reader 后可进入有界 idle lease；重入同一 source revision 时原位复用。

## 决策

1. `PipelineReaderSessionHost` 使用 factory `acquire/release`，不再直接 `create/dispose`。
2. factory 共享一个 retention pool；只保留 1 个 idle 资源会话，TTL 2 分钟。
3. retention key 使用 source/comic/chapter/sourceRevision、composition owner 和 loader URI/revision；不得使用临时 loader 对象 identity 破坏重入命中。
4. retain 时清空 Reader binding、page stream/output projection 和 playback wake，但不关闭 coordinator、DownloadRegistry、DecodeRegistry、SourcePool、media runtime 或 workspace。
5. 重入时重建 Reader binding 和 presentation output；权威 source/cursor/session 保持原对象。
6. 不同章、不同 source revision、配置不一致、TTL 到期或第二个 idle 会话进入时，旧资源会话真实 dispose。
7. 删除 Android performance-core affinity 探测、`sched_setaffinity` 和对应 ABI；`workerPlacementStatus` 暂保留为 0 以兼容 Trace schema。
8. 保留 dev.133 单 platform channel/单 blit lane，因为设备证据显示该路径相对旧版已有收敛。

## 拒绝方案

- 不建立第二套“直接 native source cache”。
- 不让 Reader 持有正文、cursor、decoded frame 或 DownloadSession。
- 不跨 Reader 复用已经使用过的 texture/SurfaceProducer。
- 不通过提高 worker 数量、线程优先级或 CPU affinity 掩盖资源重建。
- 不把 18 MiB 数据继续细分后重复灌入新会话。

## 设备验收

相同 chapter/source revision 重入时应出现：

```text
readerSessionRetained
readerSessionReused
```

且同一 retained interval 内：

- 不出现新的 `readerSessionCreated`；
- current 不再出现 18 MiB `memory-direct` source copy；
- 不重新启动整组 7/3 下载任务；
- used texture 仍重新创建，不能恢复旧 SurfaceProducer；
- 超过 TTL、source revision 变化或切换另一章节后允许重新创建资源会话。
