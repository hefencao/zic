# ADR 0164：Artifact read-through 必须保持 TaskControl capability

状态：Accepted

## 背景

dev.175 已把 `TaskControl` 接入 `DownloadJob -> ControlledTransport -> source request-plan -> external runtime`，dev.177 又让 Venera 单 invocation gate 在 current pressure 下按实时 priority 抢占。但生产 Reader 始终优先使用 `ArtifactCacheTransport` 作为最外层 transport。dev.180 中该 read-through wrapper 只实现普通 `Transport`：cache miss 后调用 `fallback.open()`。因此 `DownloadJob` 在生产路径看不到 `ControlledTransport` capability，priority/cancellation 在进入 cache wrapper 时被擦除；底层 `LoaderTransport`、Venera gate 与 rhttp 虽然支持控制面，却收不到 current 的同一 `TaskControl`。

新设备 trace 中 cached/hot page 首帧可低至十几毫秒，而 origin current 仍可在 `source-loader` 阶段等待数秒，符合“缓存读健康、origin fallback失去 current identity”的结构。

## 决策

1. `ArtifactCacheTransport` 实现 `ControlledTransport`；普通 `open()` 只是 `openControlled(..., control:null)` 的兼容入口。
2. cache lookup/read-through 不拥有新的调度策略；它只观察同一个 scheduler-owned `TaskControl`。
3. cache miss 时，若 fallback 实现 `ControlledTransport`，必须调用 `openControlled(..., control: sameControl)`；不得无条件降级为普通 `open()`。
4. 在 cache lookup、foreground materialize 与 origin response返回边界检查 cancellation；取消事实优先于“cache失败后继续origin fallback”。
5. artifact read scheduler 的priority仍来自权威 Reader demand projection；若 composition未提供 projection，可用传入 control 的实时priority作为能力级fallback。
6. origin trace记录 `controlledFallback` 与当前priority，使真机可直接确认 current=1000 是否穿过read-through层。
7. 不因此预解析整章Venera request-plan。VibeVenera同样在单图下载附近执行image-loading config；ZIC首先修 capability loss，再根据新trace决定是否需要plan warm/cache。

## 后果

生产 origin路径恢复为：

`NetLane CancelToken -> DownloadJob -> ArtifactCacheTransport -> LoaderTransport -> SourceResourceTransport -> Venera runtime gate -> rhttp`

所有层观察同一 task identity。cache命中路径、7/3下载窗口、2/1解码窗口、retained-receiving、5+1 handoff和Venera单 invocation约束均不改变。
