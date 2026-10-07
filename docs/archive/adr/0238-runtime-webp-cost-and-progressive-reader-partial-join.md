# ADR 0238：runtime WebP cost 与 Reader partial playable join 分离

- Status: Accepted
- Date: 2026-08-13

## Context
08:03 真机 Trace 纠正了 dev.258 对主问题的判断：59/59 次 `policyDecision` 都是 `animatedFlowActive=false`，完整 3/7 的 `animatedFlowFrameTargets` 全为 0，且整场没有 `mediaClassified`。对 opaque `venera-resource:`，manifest 没有 WebP extension/content-kind hint；而 runtime animation truth 只在 DecodeSession 获得 complete animation metadata 后才回传。结果形成循环：未分类 WebP 被当作不限流 body，最先 5 个 normal task 占满 NetLane，较远端只有 demand 没有连接；跳页后旧窗口 receiving task仍可 rank0 retained，新 current 才通过 reserved slot/preemption 建立连接。

同时，physical `DownloadSession.committedLength` 与新 Reader 的 decode availability 不是同一事实。新 Reader late-join 已有 hot partial 时，旧 synchronized projection 必须先把整个 committed prefix重放到新的 Reader-local native ingress，追平后才发布 source；因此 UI 可显示已有 physical partial，但 decoder 在本地整段 replay 完成前仍没有 source。

## Decision
1. encoded content kind 与 animation truth 分离。Reader/runtime 一旦从真实 ingress sniff 到 `ContentKind.webp`，只向 Pipeline 投影 runtime WebP transport-cost evidence；它可以提前启用既有 5/3/2/1 bounded body flow，但不得写入 `animated=true`。
2. DecodeSession 的 authoritative static/animated classification保持最高优先级。若某页最终证明 static，必须覆盖其 runtime WebP cost-only推断并恢复静态 unlimited body semantics。
3. runtime cost evidence 绑定当前 logical source-watch 生命周期；source generation离开/rebind时清理旧 evidence，不能变成跨 generation 的第二内容分类缓存。
4. nonresident WebP hot partial 的 Reader late join 改为 progressive projection：先按同一 decoder prefix contract重放 `firstPlayable / firstFrameRequired / unresolved quantum` 的最小前缀，发布该 Reader-local source，使 decode 可立即开始；随后只在同一 native source 上追加 artifact suffix，追平 authoritative committed boundary 后才加入 physical live fan-out。
5. resident immutable/cache replay保持原来的完整 authority replay边界，不用 hot-partial progressive join改变 durable/cache语义。
6. “较远端是否还需网络”仍唯一属于 DownloadTransferOwner。`flowTargetFrames=0` 表示 unlimited，任何未 promoted demanded partial仍需继续；positive target只有在 generation-aware frame proof、committed prefix与 decoder playable floor同时满足时才可跳过 transport。partial 字节数本身不得成为第四套 admission policy。

## Consequences
- 3/7、5/3/2/1、NetLane normal5 + current reserved1、100ms current preemption均不改变。
- opaque Venera WebP 不再需要等待完整 animation metadata 才进入 bounded body flow；前5个 unlimited body长期占满normal slots的循环被打断。
- Reader 重入已有大 partial 时，首帧只需等待最小可播放前缀的本地 replay，而不是整个 committed partial；剩余本地 catch-up 与 decode 并行，但 physical bytes仍只有一个 owner。
- source-plan/runtime invocation 的冷启动仍是独立资源问题；本 ADR 不通过扩大连接数或改变 preemption 掩盖它。
