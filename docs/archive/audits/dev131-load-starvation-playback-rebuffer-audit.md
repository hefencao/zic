# dev.131 无法加载与播放再缓冲审计

## 编译问题

- 当前输入未报告新的编译错误。

## 产品问题

- page 15（session 11）和 page 19（session 13）在挂载生命周期内没有 `firstFrameReady`。
- current 动画在已经连续播放到 frame 14 后重新进入 `playbackBuffering waiting`，表现为播放几帧后停顿再继续。

## 性能问题

- Trace 有 770 次 `decodePriorityPromoted`，其中 769 次是同一 active worker 已为 current 后重复报告，增加 Dart/Trace 噪声。
- Android worker affinity 状态均为 3（系统拒绝）；本轮不继续修改 affinity，先修确定性调度错误。

## 所有权

- source revision 是否消费、startup-buffer eligibility 与 decode follow 由 `sessions/LiveCoordinator` 负责。
- startup buffer 的生命周期由 `sessions/UploadSession` 负责。
- native pending/active 请求的 current promotion 幂等性由 `bridge/_NativeDecodeWorkerPool` 负责。
- Reader、App、Widget 不参与修复。

## 根因

1. 非 current 页面在 current startup buffering 期间收到 `sourceReady`。`_nextDecodeRefill(only: id)` 因 startup-current eligibility 返回 null，但 `_runDecode` 仍把该 source revision 标记为已消费。页面之后升为 current 时已没有 pending source revision，DecodeSession 保持 `waitingSource`，因此无法加载。
2. `UploadSession.prepare()` 在页面暂时变为 transition/previous 时同时清除 `_startupBufferSatisfied`。页面再次成为 current 后，即使动画已经播放多帧，也重新执行 startup buffer，造成中途停顿。
3. native active request 已经是 current 时，promotion 仍反复返回 `active`，导致每次 observation/source wake 都记录一次无效 promotion。

## 否决方案

- 不增加水位，不改 7/5/3/2。
- 不重新引入 visible-page demand。
- 不缩小预下载窗口或并发。
- 不通过重新下载、重建 cursor 或重建 Reader 绕过 source revision 错误。
- 不让中途 underflow 重新走 startup buffer。
