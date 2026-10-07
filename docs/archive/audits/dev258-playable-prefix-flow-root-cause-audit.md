# dev.258 根因审计：ANMF structural frame 被误当 playable frame

## 设备证据
基线：dev.257；Trace：`zic-debug-trace-2026-08-13T05-29-29.jsonl`。

- 本 Trace `downloadPreempted=0`、`Failure(cancelled)=0`、download/task/source/decode terminal failure 均为 0，说明 dev.255–257 的 partial lifecycle、monotonic proof、local-completion closure 不是本次主因。
- page206：远端预下载在 205,860 bytes 时 `completedFrames=2`，随后 `pseudo-suspended/flow-satisfied(target=2)`；但 DecodeSession frame0 已在 17,520 bytes 明确给出 `nextSourceLength=262144, decodedPrefixFrames=0`。页面进入 current 后，从 205,860-byte partial 重新打开 response；服务器 Range→200，执行 full-body prefix catch-up 后才继续 source growth，mount→first frame 约 2.451s。
- page207：245,760-byte prefix 已实际 decode frame0/frame1；后续 frame2 才要求 262,144 bytes。该页重新进入时 mount→first frame 约 112ms。
- 因而“完整 ANMF chunk 数”只能证明 RIFF/WebP 结构完整到某个边界，不能证明 native decoder 已拥有首帧所需的 VP8/VP8L/ALPH/ANMF 内部依赖和可播放 prefix。

## 根因类别
这是**事实所有权分裂**：DownloadJob 根据 transport framing 产生“frame 已满足”事实；DecodeSession 另有 `needMoreData/recordSuccess` 的真实可播放 prefix 事实。两个 owner 对“frame”使用同一术语，却不共享语义，导致 flow 在 decode 仍 waitingSource 时提前终止网络 attempt。

## 收口
- 保留 ANMF tracker，但重命名其语义为 structural frame credit。
- playable-prefix evidence 唯一来自 DecodeSession，并单向投影到 physical DownloadSession。
- suspension/proof satisfaction 同时要求 structural target 与 playable floor；decoder evidence 可使旧 proof 失效。
- 不修改 source-plan scheduler。Trace 确实还有秒级 `sourcePlan*` 冷启动，但它不能解释 page206/page207 的同类相邻页差异，应在 playable-prefix closure 真机验证后单独评估。
