# ADR 0180：高重启成本 full-body catch-up 的 sessions-owned admission

## 状态

Superseded by ADR 0181。

## 背景

dev.196 已用 validatorless overlap Range 将支持 Range 的 partial resume 重复流量压到最多约 64 KiB，并在服务器忽略 Range 返回 200 时复用同一个 full response；dev.195 的 playable partial 单调性继续成立。dev.198 的 07:51 真机 trace 仍显示：38 条可归账 origin body 约 123.17 MiB，而 `duplicatePrefixBytes` 累计约 19.21 MiB（约 15.6%）。5 次 strong-validator Range 均为 direct 206、重复为0；浪费集中在服务器明确忽略 Range 的 full-body prefix catch-up。14 次 catch-up 启动中绝大多数发生在 priority 760/780/800 的普通背景角色，相同 DownloadId 可在这些低优先级角色之间再次被调度并从 byte 0 重读数 MiB 旧前缀。

这类任务与普通可续传下载不同：一旦服务器以200忽略 Range，下一次尝试若仍要增长同一 partial，只能重新读取 `[0, committedLength)` 做 continuity proof。对大 partial 的低优先级重复尝试具有明确、可预估的重启成本；但 current/transition/next 仍需要及时增长，不能简单禁止 full-body fallback，也不能保护旧连接占用 NetLane 槽位。

## 决策

1. `NetLane` 仍是唯一网络调度权威；本决策不增加 Reader/Pipeline gate、不改变 network=5、preemption、priority migration 或 transport framing。
2. `LiveCoordinator` 在 sessions 层拥有 full-body catch-up admission：
   - `committedLength < 1 MiB` 时允许现有 catch-up，保持小 partial 的预取价值；
   - `committedLength >= 1 MiB` 时，只有动态 scheduler priority `>= 820` 才允许 full-body catch-up；因此 next/visible/transition/current 可继续，next2/previous/near/far 普通背景角色 defer。
3. validatorless Range probe 本身仍允许执行，因为支持 Range 时只需最多64 KiB overlap即可恢复；只有 probe 已返回200、或其它路径已经确认必须 full-body 时才应用上述 admission。
4. 被 defer 的 attempt 必须立即 discard 当前 full response、保持 artifact/Ingress/epoch/committedLength 不变，并将 `DownloadSession` 回到 idle；不得把 defer 表示成网络失败或 artifact reset。
5. `LiveCoordinator` 记录 deferred DownloadId，低优先级角色之间的普通 revision/priority变化不得重新开启该 task；当 demand 升到允许门槛时清除 defer并重新进入既有 NetLane。
6. admission 只读取 scheduler-owned 动态 priority 与 authoritative `committedLength`。不得读取 `duplicatePrefixBytes`、endpoint hash、rhttp timing、decode/playback状态等观测字段形成 policy。
7. 若 demand 在 response 打开期间从背景升为 foreground-adjacent，`CancelToken.priority` 的实时值优先；若升优发生在 defer 抛出与 coordinator catch 之间，coordinator 必须复查最新 demand，避免永久挂起已升为820+的页面。

## 不做什么

- 不让 full-body catch-up 变成 non-preemptible。
- 不降低 remote concurrency 5→1。
- 不为 current 增加 byte quota、token bucket 或第二 bandwidth scheduler。
- 不改变 validatorless overlap、strong validator、CRC continuity proof 或 playable partial authority。
- 不持久化“某 endpoint 永远不支持 Range”的能力判断；下一次真正需要前台增长时仍可重新 probe，以允许 CDN/endpoint 行为变化。

## 后果

支持 Range 的路径不变。服务器不支持 Range 时，大 partial 在 background 阶段停止反复从0重读；升为 next/visible/current 后再承担必要的完整前缀验证成本。该策略牺牲的是“next2/previous 对大且不可续传 partial 的继续增长”，而不是已有 playable bytes；它避免用数 MiB 可预知重复流量换取低概率背景完成，同时不阻塞新 current 的网络槽。
