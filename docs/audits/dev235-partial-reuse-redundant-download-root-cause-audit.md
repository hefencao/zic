# dev.235 Partial reuse / redundant download 根因审计

## Trace事实
输入：`zic-debug-trace-2026-08-12T02-58-57.jsonl`，5893条事件。

- `verified-transfer-acquire-alias`命中15次：11次unique existing owner、4次multi-owner `preferred-existing-owner`；physical state包含10 failed、4 receiving、1 idle，说明带committed prefix的failed/idle owner确实被新exact demand复用。
- Reader 4次dispose前physical session数为41、41、41、42，dev.234有界retention没有再出现上一轮43→50→100→107增长。
- 7次`resumeRestarted`、13次`resumeAccepted`中，4条full-body catch-up记录了非零重复prefix：73,432 + 728,792 + 7,384,680 + 5,279,360 = 13,466,264 bytes。
- 因而当前主要问题不是“partial没有复用”，而是“复用后的transport continuation仍可能重复下载旧prefix”。

## 关键因果样本
physical session `identity:<0cb18770b210a4e9,177>`：
1. pipeline-reader-1使用旧provider exact page 76，从0下载到704,512 bytes后因preemption进入failed，partial保留。
2. 新版本page 80通过verified acquire alias加入同一physical owner，`downloadStarted.committedLength=704512`，证明字节复用成功。
3. page 80随后出现`resumeRestarted strategy=full-body-prefix-catchup, strongRangeRejected=true`，说明strong Range被拒并进入200 full-body路径。
4. 后续pipeline-reader-3回到原page 76 exact URI，从同一704,512 boundary直接得到206并`resumeAccepted strategy=strong-validator-range`。

源码对照：dev.227已让`DownloadJob.requestUri`使用provider exact URI，但`DownloadSession.validators`没有request URI scope。于是B continuation会把A的ETag/Last-Modified发给B；回A又能206与该模型一致。相比“动态priority下降后中止catch-up”，这是更上游且可避免的重复下载根因；后者属于已有NetLane sunk-cost策略，本轮不改。

## 修复边界
- physical：拥有committed prefix、writer、artifact，不拥有跨provider通用validator。
- provider exact request：拥有该URI响应产生的ETag/Last-Modified。
- durable partial：以自身exact identity存储；只有validator scope与该exact URI一致时才保存validator。
- Reader/Pipeline：不新增resume policy，仅调用sessions提供的URI-scoped validator查询。

## 独立观察
本Trace仍有3次unsealed `partial-source` decode task failure；对应source length在增长，不能由本轮validator ownership修复直接解释。本轮不把decode backpressure问题混入network resume改动，留待后续独立审计。
