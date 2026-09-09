# ADR 0258：App lifecycle durable partial checkpoint 归属 Composition transfer owner

状态：Superseded

由 ADR 0307 取代。dev.279 把 `paused/detached` 当作 durable partial
checkpoint 信号的绑定已经撤销；显式 runtime safety checkpoint 能力保留，
但普通后台化不再触发正文复制。

## 背景

09:37 真机 Trace 的冷启动网络Reader已经恢复`persistentMappings=5`与verified-equivalence关系，但current及邻页首先全部`physical-local-prepare -> local-hydration-miss, committedLength=0`，current只能重新进入origin并约6.14s后得到首帧。说明版本mapping存在，缺失的是可供dev.273 indexed durable read恢复的partial bytes。

现有`PhysicalTransferRetention`只在hot partial超过32 sessions/256MiB时把unfinished prefix交给`PartialDownloadHandoff`；`CompositionDownloadTransferRuntime.dispose()`最终也会drain。但Flutter `State.dispose()`只异步调用services close，进程/Activity被系统结束并不保证最终dispose链完成，因此未达到retention压力的hot partial可只存在ephemeral workspace并随进程消失。

## 决策

1. unfinished partial的持久化owner仍唯一属于downloads层`CompositionDownloadTransferRuntime`，Reader/UI不得直接操作partial store。
2. runtime新增`checkpointPartials()`：对当前hot registry中非promoted、非disposed、非resident、committedLength>0的session生成durable safety snapshot；按effective priority、committed length排序并通过既有`PartialDownloadHandoff.persist()`顺序写入。
3. checkpoint只复制/增量更新durable prefix，不退休hot owner、不改变DownloadSession generation、不触发network retry。
4. App只作为process lifecycle signal source：进入`paused`/`detached`时请求composition checkpoint；`_AppServices.close()`必须先join正在进行的checkpoint，再进入最终transfer shutdown。重复lifecycle signal由App services coalesce。
5. 这是一条best-effort process-lifecycle durability barrier，不宣称OS在无任何lifecycle callback的强杀场景必然给足I/O时间；若真机仍证明该窗口存在，应在composition owner评估更连续的write-through，而不是让Reader保存partial。

## 保持不变

- dev.273 indexed durable partial read authority不变；cold startup仍由persistent index/file直接hit/miss。
- hot partial registry仍由composition runtime持有，retention 32 sessions/256MiB不变。
- NetLane、provider、resume validator、3/7与所有水位不变。
