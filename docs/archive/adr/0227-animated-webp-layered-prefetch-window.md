# ADR 0227：动画 WebP 分层 network admission 与稳定 3/7 逻辑窗口

状态：Superseded。细化 ADR 0067/0122 中“encoded 7/3”的 network-admission 部分；**不**取代其 RoleWindow、decode 2/1、holder 7/5/3/2 与 lane 所有权。

## 背景

dev.246 后 13:06 真机 Trace 中 destructive preemption 已降到 21 次且全部为稳定 current；但 idle Pipeline 仍固定生成 current + next7 + previous3 共 11 个 download demand。该章节实际动画 WebP 为 154 帧，正文单页常为十几 MiB，完整 3/7 网络窗口可在一个 current 周围形成超过百 MiB 的潜在 encoded 下载。继续通过 cancel retention 保护每条连接只能缓解结果，不能降低同时 admitted 的昂贵 speculative work。

同时，历史 3/7 不能直接缩成动态 2/4：`RoleWindow` 还承担 previous/next/near/far 与 retained-output 的逻辑归属；跳页后“页面是否仍在稳定窗口内”必须继续以 3/7 判断，否则会重新制造 detach/recreate、partial 不复用与 output retention 回归。

## 决策

1. `RoleResolver` 的 stable encoded **逻辑/retention** envelope 固定保持 previous3 / next7；scrubbing 现有 current-only 特例不变。
2. 新增 Pipeline-owned `AnimatedPrefetchPolicy`，只决定该 RoleWindow 中哪些 index 创建 **network download demand**。Reader、sessions、DownloadSession 与 NetLane不得复制该策略。
3. 当前页为 runtime animated 时启用分层 admission；runtime 尚未决议时，`animatedHint`、WebP content kind/URI suffix仅可作为**保守网络成本提示**启用同一窄窗，不得写入 animation truth、Reader orientation 或 adaptive profile。runtime 明确 static 时立即恢复完整 3/7 network admission。
4. 动画 network admission 硬下界为 current + previous2 + next4。该 count floor 不能被字节预算缩小；如果 floor 自身已经超过预算，只记录 `minimumExceedsBudget` 并禁止额外扩张。
5. 外层按既有 decode staged waterline 的**成功完成事实**单调开放：`c>4 → next5`、`n>2 → previous3`、`c>6 → next6`、`n>3 → next7`。sessions只报告成功 refill milestone；Pipeline决定是否扩张。
6. speculative encoded budget 默认 50 MiB，可由 App 网络设置配置。已知 `PageAsset.byteLength` 使用真实 manifest cost；未知长度使用保守估计。预算只约束下界外的额外页面；current不计 speculative cost，可见 transition 不是 speculation。
7. waterline milestone 必须带原 demand revision；Pipeline只接受仍等于当前 plan revision 的 milestone。跳页或 replan 后旧 decode 完成不得重新打开新 current 的外层下载。
8. 任何 admission 裁剪都不得改变 `RoleWindow.roleOf()`、`retainedIndex`、physical alias/partial identity 或“仍在3/7内”的跳页判断。页面成为 current、visible transition或重新进入2/4下界时，应通过既有 acquire-before-projection owner复用 physical partial。

## 否决方案

- 直接把 `RoleResolver` 从3/7改成2/4：会混淆逻辑窗口与网络成本，破坏跳页/retention语义。
- 以 WebP 扩展名硬判“真实动画”：违反 runtime classification ownership；这里只允许其作为保守成本提示。
- 在 sessions 根据 holder depth直接增删 download demand：把网络 policy泄漏到执行层。
- 50MiB预算优先于2/4硬下界：会使窗口形状随单页大小随机缩成1/2等不可预测状态。
- 通过降低network concurrency或继续增加cancel hysteresis解决动画窗口过大：只改变竞争结果，不减少不必要的 speculative demand。
