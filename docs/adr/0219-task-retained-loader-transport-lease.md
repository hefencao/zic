# ADR 0219：task-retained loader transport lease

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.239
- Supersedes ADR 0218 中“provider consumer真实dispose必然取消active attempt”的无条件规则；ADR 0218 的claim orphaning、strict higher-priority handoff与single physical owner继续有效。
- ADR 0220进一步细化claim orphaning：普通低优先级orphan retention继续有效，但不同exact provider的NetLane high-priority demand可reclaim request/provider authority。

## 背景

dev.238后的05:09真机Trace共1176条事件，`taskFailed=0`，未再出现仅由claim orphaning触发的provider handoff或`full-body-prefix-catchup-aborted`；resume重复流量仅有一次65,536-byte validatorless overlap proof。说明logical claim与admitted attempt已经成功解耦。

剩余断点发生在Reader consumer真实dispose：已有4,064,640、4,763,980、7,994,960 bytes等hot physical partial的active task仍因Reader dispose取消。后续Reader继续复用同一physical session时必须重新open/resume，其中4,064,640-byte partial的Range probe得到HTTP 200并进入full-body prefix catch-up。该取消并非physical owner、partial或provider identity失效，而是所有transport此前被一律视为Reader-owned。

Pipeline实际存在两类不同lifetime的transport：Reader-owned `IoTransport`会在Reader dispose后关闭；loader-backed `LoaderTransport`自身无closeable socket/client，其controlled loader由composition/source gateway提供，能力生命周期可独立于单个Reader route。

## 决策

1. physical `DownloadSession`、writer、committed prefix、NetLane task与task-scoped provider lease继续是唯一transfer authority；不复制partial、不建立第二scheduler。
2. `DownloadTransferConsumer` MAY额外提供通用`retainedTransportFor(uri)`能力。active task只在真正启动时解析一次；返回非空即表示该transport lease可独立于consumer dispose存活。
3. provider consumer dispose MUST取消并等待所有consumer-bound active lease物理退出；已经持有task-retained transport的lease不进入该close barrier，可继续同一writer/partial。
4. Pipeline只在URI由当前immutable `LoaderTransport` source map拥有时提供task-retained transport；该read-through transport可包含artifact-cache facade，但其origin fallback仍必须解析到同一loader-backed URI。Reader-owned `IoTransport`不得作为retained transport返回。
5. sessions/downloads只认识“transport是否task-retainable”的通用capability，不得知道Venera、Mihon、external source、Reader route或source gateway，也不得建立第二provider/source registry。
6. retained attempt继续服从同一NetLane priority、cancel/preemption、retry与physical session authority；live strict-higher preferred claim的dev.237 handoff规则不变。
7. `downloadStarted`记录`providerTransportLifetime=task-retained|consumer-bound`，用于设备证据区分transport owner，而非驱动policy。

## 非目标

- 不让所有transport无条件越过consumer dispose；`IoTransport`关闭边界继续严格保留。
- 不修改Range/validator/full-body catch-up阈值，不用调参掩盖transport lifetime错误。
- 不修改Reader progress语义；duplicate prefix仍不得变成synthetic progress。
- 不把source-specific生命周期判断下沉到sessions/downloads。
