# dev.237 active provider lease root-cause audit

## 用户现象

切换到另一个logical/Reader session后，partial进度能够看到已有值，但随后长时间不增长。

## 04:17 Trace 证据

- Trace 共 3663 条事件。
- 代表性 physical session `download:-59abada411a1459` 已有 `committedLength=6,596,280`。reader-2 以另一个 provider exact identity 进入 full-body prefix catch-up。
- reader-2 demand 在约 32.25s 撤销后，该 receiving task被既有 retained-background语义降到priority 0继续执行。
- reader-3 在约34.34s成为current并对同一physical session施加priority 1000，但只有`downloadPriorityChanged 0→1000`；没有新的provider open。旧reader-2 provider attempt继续重读旧前缀，到约40.71s被取消时已产生6,276,540 duplicate prefix bytes。
- 同一physical session随后reader-4 attempt再次进行full-body catch-up，最终完整重读6,596,280 bytes旧前缀后，`bytesCommitted`才从6,596,280继续增长到6,876,600等。
- 因而dev.236 progress publisher没有“漏掉正在增长的committed bytes”；底层authority在重复验证旧prefix期间本来就没有增长。

## 根因

`DownloadTransferOwner._runDownload`在task开始时通过`_preferredClaim(id)`一次性捕获provider consumer与exact request identity。之后claim revision/Reader切换只通过`NetLane.updatePriority`迁移同一个task的rank，无法改变该task正在使用的provider transport/URI。于是physical writer虽然已经统一，active provider lifecycle仍隐式属于最初启动task的Reader consumer。

这形成了不完整的解耦：

- physical bytes/writer authority：shared；
- scheduling priority authority：aggregated claims；
- active provider authority：仍被task birth consumer钉住。

## 修复边界

- 将active provider显式记录为task-scoped lease。
- claim更新后，如果lease claim已撤销，或新的preferred live claim priority严格更高，取消旧attempt；旧writer退出后仍由相同physical session从现有committed boundary重开preferred exact provider。
- equal priority不切换，避免provider ping-pong。
- 取消/重开通过现有NetLane/DownloadJob路径，不增加第二retry owner。
- progress仍只投影committed authority；duplicate prefix不计progress。

## 拒绝方案

- **UI synthetic progress**：会把重复网络字节伪装成新的可播放authority，拒绝。
- **每logical session复制partial/progress**：重新制造第二owner，拒绝。
- **Reader直接取消旧provider**：让consumer拥有network lifecycle，拒绝。
- **任意claim变化都重开provider**：会把正常prefetch revision变成transport churn，拒绝。
- **立即修改full-body admission**：本轮先修provider ownership漏口；真实服务器忽略Range的fallback仍是独立问题。
