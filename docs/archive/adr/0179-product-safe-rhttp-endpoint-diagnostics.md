# ADR 0179：product-safe rhttp endpoint diagnostics 与显式 receive-progress 诊断构建

## 状态

Accepted。

## 背景

dev.197 的 06:36 真机 trace 已把导出体积从上一份约 1.79 MB / 5502 events 收敛到约 1.27 MB / 3287 events，同时保留完整网络生命周期。该 trace 中可归账 origin body 约 101.6 MiB，`duplicatePrefixBytes` 约 4.32 MiB（约 4.25%）；2 次 strong-validator resume 仍为 direct 206，剩余重复来自服务器忽略 Range 后的 full-prefix fallback。并发 body 越多时聚合吞吐仍上升，current=1000 的 Venera gate wait 中位接近 0，因此现有证据不足以支持降低 network=5 或增加 current 独占带宽。

但 dev.195 从 dev.192 重做时，product/release 又回到“不注册 rhttp `onReceiveProgress` 且不输出 endpoint/version 元数据”的状态。普通 release trace 因而只能看到 DownloadJob/session-copy chunk gap，无法按匿名 endpoint 区分 CDN 差异，也无法在需要时比较 native receive-progress 与 Dart body delivery。

## 决策

1. rhttp direct response 的 `HTTP version`、匿名 `remote-IP hash` 与 `sourceRhttpReceiveProgressEnabled` 是每个 response 一次的低开销元数据，product/release 默认输出。
2. 高频 `onReceiveProgress` 仍不在普通 product/release 默认注册。non-product 构建保持启用；product/release 只有显式 `--dart-define=ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=true` 时启用。
3. `tool/build_android.sh` 接受 `ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=0|1`，值为1时只附加上述 dart-define，不改变 native build、网络并发、Range、retry 或 Reader/Pipeline策略。
4. `tool/analyze_frame_pipeline_trace.py` 增加匿名 endpoint hash 计数，便于比较同一 endpoint 上不同 priority/并发时的吞吐；hash 不得反解或写入业务 identity。
5. `sourceRhttp*` 与 endpoint/version 仍只读 observation，不得成为 NetLane、Reader、retry、cache、framing 或 bandwidth policy 的输入。

## 不做什么

- 不默认给 release 常驻高频 FFI progress callback。
- 不改变 rhttp raw stream cadence、DownloadJob 16/64 KiB 单一 aggregation、network=5、priority、Range/resume 或 playable-partial authority。
- 不因为 current 单流慢就新增 transfer-pressure/bandwidth scheduler。

## 后果

普通 release trace 可以先按匿名 endpoint / HTTP version 排除 CDN 节点差异；若同 endpoint 仍出现 current 特异性停顿，再用显式 diagnostic release 收集 receive-progress/body lead。只有该证据证明 native receive平滑而 Dart body delivery长期落后，才继续调查 rhttp FFI/backpressure；否则保持网络策略不变。
