# dev.254 根因审计：silent decode failure 与 consumer pacing 水位失真

## 输入
- 唯一代码基线：dev.253完整包。
- 真机Trace：`zic-debug-trace-2026-08-13T02-27-59.jsonl`，5683条事件。

## 设备事实
- `taskFailed=0`、`sourceDisabled=0`、`downloadPreempted=4`，网络抢占已不是主要故障。
- Trace有2次`decodeState=failed`且没有对应taskFailed。page335约39.67s成为current；其physical task从`consumerPacing target=1`原地`pseudo-resumed target=0`，committed bytes随后由约8.36MiB快速增长到15.1MiB，并约40.19s seal、40.21s promote；但DecodeSession约39.829s已直接failed，upload随即failed，host约42.54s dispose时仍无first frame。
- `consumerPacing`共1832条flow事件，其中1800条是`pseudo-drain`。target=1共1160条，completedFrames中位38、最大122；target=3中位73、最大132；证明周期drain持续越过Pipeline frame credit。
- 多个远端target=1任务在Trace后段仍以completedFrames 19/37/115/157继续`pseudo-drain`，不是短暂chunk误差。

## 根因
1. DecodeSession同时持有physical DownloadSession与Reader-local ingress projection，使用两套epoch authority。physical generation早已由source-watch/ingress registry完成映射，decode再次读`download.epoch`会把合法projection generation变化误判为staleEpoch并静默`_setFailure`。
2. LiveCoordinator仅对`fill()`抛出的异常执行统一failure路径；`fill()`直接返回failed snapshot时仍先写`_decodeSourceRevisions`，把后续可恢复source evolution当成已消费。
3. `consumerPacing`以每100ms放行一个chunk维持response，无法形成帧上限：时间越长越会下载完整动画。unsupported upstream pause无法同时保证永久连接保留与网络流量停止。

## 收口
- decode generation owner唯一为Reader ingress projection；physical session从DecodeSession移除。
- returned failed snapshot不能静默消费source revision。
- consumerPacing由无限pseudo-drain改为100ms bounded same-response dwell后policy suspension；writer正常pause、partial保留、相同frame target不自重开，target提升才resume。
- 不改3/7、frame-credit数值、NetLane并发/rank或partial identity。
