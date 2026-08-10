# dev.195：从 dev.192 重做可播放 partial 生命周期根因审计

## 基线与失败实验隔离

本轮唯一代码基线是 `zic_v0.31.0-dev.192_rhttp-transfer-stage-observation.zip`。dev.193/dev.194 交付整体视为失败实验，不参与源码合并、cherry-pick或实现复用；只使用其真机 trace 说明为什么需要回到更早的不变量。

`zic-debug-trace-2026-08-10T01-56-33.jsonl` 来自失败实验线，显示多个不同大小的 partial 同时进入 `full-body-overlap-catchup`，并出现 strong-validator rejected 的独立 terminal 分支。这说明后两轮已经把 resume protocol、artifact authority 和播放行为扩成过多相互作用的状态。

## dev.192 的两个基础错误

### 1. resume 失败会销毁 authoritative partial

原 dev.192 `DownloadJob` 在以下任一条件直接 `session.reset()`：

- `committedLength > 0 && !validators.canResume`；
- partial 对应 durable immutable response；
- `requireResumeResponse` 返回 `resumeRejected`。

但这些事实只说明本次网络续传方式不能被证明正确，不说明已经下载并被 decoder 使用的 `[0, committedLength)` 已损坏。`reset()` 会删除 partial、推进 SourceEpoch、reset Ingress并清除 content kind，因此网络生命周期错误地获得了降低 playback authority 的权限。

### 2. 每个新的 DownloadJob run 都会重建 Ingress

`DownloadJob._run()` 开始调用 `session.restore()`；dev.192 restore 对 partial/promoted artifact 无条件 `_rebuildIngress()`。因此即使没有执行 `reset()`，同一内存 session 的网络 attempt重启也会重新创建/灌入 encoded source，可能造成播放短暂停顿和 revision抖动。

## dev.195 收口

- strong validator Range成功路径不变；
- 其它 resume fallback 统一为 full-body prefix catch-up，不建立 validatorless Range/overlap状态机；
- catch-up 在旧 boundary前不写 artifact/Ingress，以现有 artifact CRC32验证完整重复前缀；
- mismatch/cancel/EOF保留旧 partial与epoch；
- matching Ingress 的 restore变成幂等操作；
- broken/missing resume metadata不再删除 media bytes，只有明确 wrong owner才重启 artifact；
- DecodeSession、Reader/Pipeline、NetLane与rhttp raw-stream framing保持dev.192原样。

## 仍需真机验证

当前环境没有 Dart/Flutter，新增的行为测试不能在本轮执行。dev.195真机必须重点确认：

1. 同一 DownloadId 网络重启前后 `committedLength/sourceLength/epoch` 不下降；
2. `full-body-prefix-catchup` 的 `resumeAccepted` 只在网络已追平旧 boundary 后出现；
3. catch-up期间没有 `reset=true`；
4. 若 sourceLength稳定但动画仍停播，再单独审计dev.192既有 partial-loop，不把该问题提前混入本轮。
