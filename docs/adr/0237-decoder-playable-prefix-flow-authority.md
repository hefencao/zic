# ADR 0237：decoder playable-prefix 是动画预下载 suspension 的可播放事实

- Status: Accepted
- Date: 2026-08-13

## Context
05:29 真机 Trace 证明 `WebpFramePrefixTracker.completedFrames` 与 decoder 可播放性不是同一事实。page206 在 205,860 bytes 时已经包含 2 个完整 ANMF chunk，因此 network target2 被判 `flow-satisfied`；但 DecodeSession 在同一页 frame0 上明确返回 `needMoreData`，下一次至少需要 262,144 bytes。页面随后切成 current，只能重新打开 provider response、执行 full-body prefix catch-up，首帧仍约 2.45s。对照 page207 在 245,760 bytes 已实际成功解出前两帧，重新切入首帧约 112ms。

## Decision
1. `WebpFramePrefixTracker` 只拥有 encoded structural progress；ANMF count 不再单独授权 pause/suspension。
2. DecodeSession 是 playable-prefix 唯一事实来源，暴露当前 ingress generation 的 `decodedPrefixFrames`、`firstPlayablePrefixBytes`、`firstFrameRequiredSourceLength`。
3. LiveCoordinator 仅通过现有 generation-aware source-watch binding 把上述只读 evidence 投影到当前 physical DownloadSession；DecodeSession 不重新持有 DownloadSession、NetLane 或 transport。
4. physical DownloadSession 保存本 generation 的 first-frame playable/required prefix evidence。未有成功证据时使用与 `WebpDecodePrefixHints` 相同的 source-kind quantum 作为 unresolved floor；decoder `needMoreData` 可提高 floor，真实 frame0 success 可收紧为最小成功 prefix。
5. DownloadJob 只有在 structural frame target 已满足且 authoritative partial 达到 playable floor 时才可进入 `paused/pseudo-suspended`。stream-backpressure 等待期间周期重查 evidence；consumerPacing 100ms 后也必须重查后才能 suspend。
6. TransferOwner 的 monotonic frame proof 继续表示 physical structural frame prefix，但 proof satisfaction 必须同时满足当前 playable floor。decoder evidence 抬高 floor 后，已有 demand 自动从同一 partial 继续，不等待 role/target 变化。

## Consequences
- 3/7 network demand、5/3/2/1 policy、NetLane 5+current reserved1、provider identity 均不改变。
- 远端页面可能比旧实现多取少量 encoded bytes，但不会在 decoder 已明确“不够首帧”时错误停止。
- source request-plan/runtime 的冷启动延迟仍是独立问题；本 ADR 不用 flow 修复掩盖它。
