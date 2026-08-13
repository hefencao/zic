# dev.262 根因审计：3/7内 non-range flow suspension 导致真实prefix replay

## 设备事实（09:59 dev.261 Trace）

- page102 / physical `identity:<1d1c13bdc9e01061,178>` 初始在current=100时以priority800进入next2。
- runtime确认WebP后target=3；9.150301s在452,600 bytes、3 structural frames、playable floor 280,320 bytes时`pseudo-paused`，9.253178s被`pseudo-suspended`。首attempt的sourceRead为HTTP 200、total 17,582,828 bytes、读取452,600 bytes且`completed=false`。
- current随后100→101，page102成为next1；10.173294s同physical identity第二次`downloadStarted`，committedLength仍452,600，target5/retain=true。
- Range overlap probe返回HTTP 200，10.577076s进入`full-body-prefix-catchup`；11.090399s明确记录`duplicatePrefixBytes=452600`。因此不是UI重复、partial丢失或连接计数误读，而是452,600真实prefix网络重放。
- 用户随后反向切页；page102从next1退回next2，11.464083s priority820→800，11.467437s在751,900 bytes再次`pseudo-suspended`。旧策略因此会在前后振荡中反复制造同类reopen机会。
- 对照Trace中immediate adjacent已有`pseudo-retained → pseudo-resumed`样本且无中间第二次start，证明dev.260/261 metadata/lifecycle闭包不是本轮根因。

## Issue / authoritative owner / rejected fixes

- Issue：bounded body credit错误拥有了“无条件终止consumer-paced response”的权力。
- authoritative owner：transport提供`ByteResponse.rangeSupported`能力事实；DownloadJob flow gate据此决定“credit满足后是否允许主动suspend response”；NetLane仍唯一拥有pressure/preemption/cancel。
- rejected：扩大连接数、延长grace、提高partial/restart bonus、把整个3/7无条件warm、直接full-body drain。

## dev.262修改

- `_WebpNetworkFlowGate`接收`response.rangeSupported`。
- `consumerPacing` blocked时，`retainFlowResponse || !rangeSupported`均进入同task bounded `pseudo-retained`；只有`rangeSupported && !retainFlowResponse`进入`pseudo-suspended`。
- flow trace增加`responseRangeSupported`；capability驱动的retention记录`retentionReason=range-resume-unproven`。
- 新Dart regression覆盖non-range outer positive target→foreground target0期间openCount保持1；既有range-supported远端suspension测试保留，防止退回无限pseudo-drain。
