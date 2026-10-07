# dev.268 根因审计：pseudo pause 仍销毁 live response

## 设备事实

输入：`zic-debug-trace-2026-08-13T14-54-50.jsonl`。

Trace 中可见多个 identity 先进入 `pseudo-retained`，随后在 working-set claim 消失后被 `downloadPreempted(preemptionReason=inactive-reclaim)`；之后同 identity 再次出现新的 `downloadStarted` / `resumeRestarted`，Range 被拒绝或返回200时继续 full-body prefix catch-up。另有 Range-capable identity 在 positive flow target满足后出现 `pseudo-suspended`，其 `sourceRead` 以 `completed=false` 结束，随后再次 open。

这说明 dev.267 只把 logical detach 与 task cancellation 分离了一半：physical task可以暂时保留，但 NetLane 仍用同一“active slot”同时代表 live response 与5路读取额度。要让新 demand前进，只能取消 inactive task；因此所谓 retained response最终仍被释放。

## authoritative owner

- Pipeline：Reader 3/7 demand、role/rank、5/3/2/1 target。
- DownloadTransferOwner：consumer claims → physical task identity/demanded projection。
- DownloadSession：partial/writer、playable-prefix evidence、physical generation frame proof。
- NetLane：body-read permit admission/resume、parked-response bounded pool、真实 preemption/eviction。
- DownloadJob：同一个 ByteResponse/StreamIterator 的 read/park/resume 生命周期。
- rhttp direct transport：实际 response/socket 与 cancellation；不得自行拥有 Reader/scheduler policy。

## rejected fixes

- 再增加 next2/previous2/near/outer protection flag：继续让 Reader角色泄漏到 scheduler lifetime。
- 调大3/7或方向切换阈值：只延迟 claim churn，不解决 response owner。
- `inactive-reclaim` 改更严格 priority：仍然以 cancel response 作为释放5路的唯一方式。
- 保持 `pseudo-retained` 每100ms读取一chunk：response虽然暂时不关，但仍占 slot，最终重新制造 starvation/reclaim；同时不是“pause”。
- 无界保留 response：HTTP/1.1 socket/native buffering不可控，不能接受。

## dev.268 closure

将 NetLane 的 `active` 重定义为 body-read permit occupancy，并保留独立 `running/parkedResponses`。DownloadJob 在 flow/demand park 时只释放 permit，保持同一 response iterator；后续重新获得 permit后原地继续。只有 parked pool 超限、显式 lifecycle、真实 failure 或 current-only destructive preemption才结束 response。
