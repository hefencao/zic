# dev.279 本地重入与冷启动 partial 退化根因审计

## 设备事实：09:37 Trace

### 本地 Reader re-entry

- page5第一次进入约304ms首帧；短期retention后第二、第三次分别约366ms/357ms。
- 每次re-entry都连续出现约11个`reader-source-watch-rebind / physical-generation-changed`。current记录`invalidatedUploads=1 / invalidatedDecodes=1`，已有热邻页decode也被失效。
- 这些页面是本地immutable source；same exact DownloadId仍稳定，只是composition重新创建了concrete DownloadSession object。
- 因而卡顿回归的上游不是dev.278 UploadRegistry binding，而是dev.277将“physical object换代”无条件等同为“Reader encoded bytes换代”。dev.278只使这个过宽invalidaton之后的binding更安全。

### App冷启动 partial

- startup已经恢复版本mapping：`persistentMappings=5`，verified equivalent pages仍存在。
- 网络Reader current/邻页最初均`local-hydration-miss / committedLength=0`，随后current重新等待origin，约6.14s得到首帧。
- 这说明dev.273 durable lookup本身工作正常，但persistent partial store中没有可恢复prefix。
- 源码确认未达到32-session/256MiB retention压力的hot partial只在composition ephemeral workspace；除了retention eviction，只有最终`CompositionDownloadTransferRuntime.dispose()`才drain。Flutter route/App dispose的异步close不是process-death durability guarantee。

## dev.279 收口

1. sealed + sourceReady + no-failure且无pending late attachment的Reader projection成为immutable encoded-generation authority。same exact DownloadId仅physical DownloadSession object重建时保留该projection与热decode/upload；mutable/incomplete generation仍严格更换。
2. old same-id physical teardown增加concrete identity guard，禁止删除已转移给replacement session的projection entry。
3. composition runtime新增process-lifecycle partial checkpoint；App paused/detached只发signal，实际durable I/O仍由`PartialDownloadHandoff`执行。close必须join checkpoint。

## 下一Trace判据

- 本地二次进入：same exact sealed source应看到`sealed-source-generation-preserved`且`invalidatedUploads=0 / invalidatedDecodes=0`；已有热decode/upload不应因transient physical session object换代全部重建。
- 冷启动：若退出前存在committed hot partial且lifecycle checkpoint有机会完成，重启后physical local prepare应出现durable partial hit/restore而不是所有相关页`committedLength=0` miss。
- 若冷启动仍丢partial，先补checkpoint trace确认lifecycle callback是否发生/持久化是否完成，再决定是否需要composition-owned更连续write-through；不得直接回Reader层保存。
