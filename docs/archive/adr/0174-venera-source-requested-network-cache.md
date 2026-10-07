# ADR 0174：Venera Source-Requested Network Cache 语义

## 状态

Accepted。补充 ADR 0170–0173；不改变 Reader/NetLane priority、Venera single-invocation permit 或最终图片 host transport。

## 问题

`zic-debug-trace-2026-08-09T14-12-27.jsonl` 的18个 origin request-plan样本显示：`sourceRequestPlanMicros`中位约3.016s，其中`sourcePlanGateWaitMicros`中位约1.742s、`sourcePlanHookMicros`中位约1.392s、`sourcePlanBridgeNetworkMicros`中位约1.368s；18/18样本的`sourcePlanBridgeNetworkCalls`都等于4。JS hook自身除bridge network外只有很小开销，single-invocation gate主要在排队重复resolver网络。

当前E-Hentai source的`onImageLoad`会重复调用`loadThumbnails`、`getKey`、必要的thumbnail page，再POST API生成最终图片URL。前述GET显式携带Venera `cache-time: long`与`prevent-parallel: true`。ZIC bridge此前没有实现这两个Network控制语义，且将其作为普通HTTP header转发，因此本应复用的gallery/key HTML在每张图都重新出网；随后single-invocation将重复网络串行化成gate wait阶梯。

## 决策

1. `cache-time`、`prevent-parallel`是Venera `Network.*`控制字段，不是origin header；native HTTP前必须剥离。
2. `VeneraNativeBridge`拥有runtime-local GET response cache。它只服务source hook/metadata resolver网络，不进入`ResourceCacheManager`、DownloadSession、artifact或Reader/Pipeline。
3. 对齐Venera当前关键语义：`cache-time: long`命中窗口6小时；普通短命中5秒；仅缓存status<400、body非空且小于1MiB响应；总缓存限制10MiB。
4. cache identity按URL加真实请求header比较；Cookie差异必须使缓存失配。与Venera一致忽略仅控制/响应元数据以及authorization等既有compareHeaders忽略项。
5. 当前Venera runtime物理single-invocation已经保证同一source的bridge HTTP不会并行进入，因此满足比`prevent-parallel` same-path等待更强的不并发约束；本轮不新增第二锁调度器，也不扩大JS并发。
6. cache hit响应增加`venera-cache: true`诊断header。JS plan metrics新增`sourcePlanBridgeNetworkCacheHits`和`sourcePlanBridgeNetworkOriginCalls`；这些值只用于trace，禁止成为scheduler/cache/retry决策输入。
7. 最终图片body仍由`SourceResourceTransport` native host transport执行；本ADR的runtime cache不得缓存章节图片body，也不得改变`__zicCancel`边界。

## 后果

- E-Hentai首次page仍可能为gallery/key/thumbnail-page产生origin GET，但后续同gallery/page-group应快速复用这些resolver结果；逻辑`Network.*`调用数可以保持不变，而真正origin调用显著减少。
- single-invocation仍保留插件状态安全边界，但不再被重复的source-requested cacheable resolver网络放大。
- 若dev.191后`sourcePlanBridgeNetworkCacheHits`正常增加而gate wait仍长，再继续审查不可缓存的API POST或single-invocation临界区；不得先扩大Venera并发。
