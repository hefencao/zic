# ADR 0178：Debug Trace 语义导出压缩与流式诊断视图

## 状态

Accepted。

## 背景

大规模 Reader 真机 trace 同时承担网络、播放、调度与失败诊断。运行时必须保留足够细的事件边缘，但直接把所有高频采样逐条导出会使 JSONL 快速膨胀，增加用户上传、检索和离线分析成本。

dev.196 的 05:28 真机 trace 共 5502 条事件、约 1.79 MB。网络归账显示 Range continuity 已经有效：可归账 origin body 约 177,601,680 bytes，其中 `duplicatePrefixBytes` 约 2,996,334 bytes（约 1.7%）；3 次 strong-validator resume 均直接得到 206。剩余最大重复发生在服务器忽略 Range 返回 200 后，用户从旧区域远跳，旧 full-body fallback 随 detach 很快取消。该证据不足以支持新增 restart-cost scheduler。

trace 体积的主要来源反而是高频诊断事件：`framePipelineTiming`、`bytesCommitted`、`downloadPriorityChanged`、`decodeRefill`、demand/state 等。其中 `framePipelineTiming` 和 `decodeRefill` 已携带可合并统计结构，适合只在导出边界做语义压缩。

## 决策

1. **运行时 Trace 不变**。状态所有者仍按原粒度产生事件；调度、下载、播放、错误恢复不得读取导出压缩状态。
2. **App export projection 可语义合并高频诊断**：
   - `framePipelineTiming` 至少按 `traceReason + dominantStage + role + decodedRole + uploadRole` 区分语义桶；
   - `decodeRefill` 至少按 `role + stage + sourceWake` 区分语义桶；
   - 桶内保留 `coalescedCount`、first/last frame，并对关键 timing、`sourceLength/sourceRevision/consumedSourceRevision` 保留 min/max。
3. **权威边缘不得因本优化折叠**：错误、retry、writer rejection、resume、`sourceRead`、download start/state/priority、session retain/reuse 和生命周期边缘继续逐条保留。
4. 新增 `tool/filter_debug_trace.py` 作为离线流式诊断工具，支持 `network/playback/failures/all` profile，并可按 identity/session 缩小范围。工具逐行处理 JSONL，不把整份 trace 加载进内存。
5. 过滤文件只是分析视图，不是业务事实或持久状态。原始 trace 仍是完整诊断源。

## 不做什么

- 不改变 DownloadJob、DownloadSession、DecodeSession、Reader/Pipeline 或 NetLane 行为。
- 不调整 network=5、优先级、水位、Range/resume 或 bandwidth policy。
- 不为了缩小 trace 删除错误、resume/sourceRead 或关键 lifecycle 边缘。
- 不把 export coalescing 结果反馈给运行时调度、重试、缓存或播放策略。

## 后果

对高频 timing/refill 事件，导出文件会显著缩小，同时保持诊断所需的语义边界和极值。对于只分析网络的场景，流式 `network` profile 可进一步将大 trace 裁剪为只含页面/调度边缘、download/resume/sourceRead/sourceReady 等必要事件的小 JSONL。
