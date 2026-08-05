# ADR 0114：保留被暂缓 Source Wake 与单次启动缓冲

**状态：Superseded by ADR 0115 in dev.132**

## 问题

dev.130 设备 Trace 中有页面在 source 完整 ready 后仍整个挂载生命周期没有首帧；同时动画已播放多帧后因临时角色变化再次进入 startup buffering，表现为播放几帧、长暂停、再继续。

## 决策

1. 当某 DecodeId 因另一个 current 的 startup buffering 暂时不具备 refill eligibility 时，不消费它的 source revision。该 revision 保持 pending，后续角色变化或 current promotion 继续触发同一 DecodeId。
2. `decode-startup-deferred` 只记录真实被 gate 暂缓的 source wake，不创建 timer、不复制 source、不重建 cursor。
3. startup buffer 的“已完成”状态属于当前 UploadSession output 生命周期。临时 transition/previous 只取消未完成的等待，不清除已经完成的状态。
4. output 真实丢失、session detach/dispose、decode epoch 重建或播放生命周期重置时，仍按原路径清除 startup 状态。
5. native active request 已是 current 时，重复 promotion 返回 none。

## 所有权

- source revision 与 decode eligibility：`sessions/LiveCoordinator`。
- startup buffer 生命周期：`sessions/UploadSession`。
- native promotion 幂等性：`bridge/_NativeDecodeWorkerPool`。
- Reader 与 App 不参与。

## 拒绝方案

- 不增加水位或改动 7/5/3/2。
- 不恢复 visible-page demand。
- 不缩小下载窗口或降低并发。
- 不通过重下、重建 cursor 或重建 Reader 绕过 pending source revision。
- 不把播放中 underflow 重新解释为 startup buffer。

## 解除 Provisional 条件

设备 Trace 中 `pageHostDisposedWithoutFrameCount=0`、`playbackRebufferCount=0`、`playbackBufferingOutstandingCount=0`；出现 `decode-startup-deferred` 的页面在升为 current 后可及时产生 frame 0。
