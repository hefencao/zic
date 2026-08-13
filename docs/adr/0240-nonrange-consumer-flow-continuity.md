# ADR 0240：无可靠 Range resume 的 consumer-paced response 连续性

状态：Accepted

## 背景

dev.260只为immediate next/previous增加`retainFlowResponse`，解决“next1达到水位后约100ms即升current却先主动关response”的问题。09:59 dev.261真机Trace证明该闭包本身有效，但暴露第二类3/7内重开：page102在current=100时为next2，452,600 bytes已满足target3和playable floor，于9.253s按旧规则`pseudo-suspended`；current=101后它成为next1，于10.173s从同一partial重新`downloadStarted`。Range probe得到HTTP 200而非206，full-body catch-up最终记录452,600 duplicate prefix。反向切页后同一response在751,900 bytes又因next1→next2再次被主动suspend。

因此问题不在5路连接、partial retention或dev.261 metadata迁移，而在一个错误前提：**positive body credit满足并不意味着当前response可以低成本关闭。** 若transport没有正面证明Range resume，关闭response会把保留partial转换为下一次真实prefix replay。

## 决策

1. `ByteResponse.rangeSupported`继续是typed transport capability。flow policy不得从`sourceRead`/HTTP diagnostics等观察字段反推该事实。
2. `consumerPacing`达到structural + decoder playable credit后：
   - `retainFlowResponse=true`：维持dev.260 adjacent warm retention；
   - `rangeSupported=false`：即使retain bit为false，也保持同一个已admit response/task，记录`pseudo-retained`，最多每100ms消费一个body chunk；
   - 只有`rangeSupported=true && retainFlowResponse=false`才进入`pseudo-suspended`并pause authoritative writer。
3. target变0或credit提高后，仍由同一CancelToken唤醒并`pseudo-resumed`。
4. 真实NetLane priority pressure、current destructive preemption、consumer/runtime cancellation仍可结束attempt；本ADR只删除“frame credit满足→无条件主动关non-range response”这一第二终止owner。
5. retained response继续计入原NetLane active/bucket槽。normal5 + current reserved1不变，不新增隐藏连接。
6. 本ADR不恢复dev.231-era全窗口无限`pseudo-drain`：Range-resumable远端页仍按5/3/2/1释放response；non-range例外只承认“硬cap与零prefix replay无法同时成立”的transport约束，并保持已有100ms bounded consumer pacing，而不是主动full-body drain。

## 被拒绝方案

- **把3/7全部设置`retainFlowResponse=true`**：忽略transport capability，让可安全Range resume的远端页也长期占slot，破坏5路轮转。
- **增加grace/提高连接数/partial bonus**：只掩盖当前Trace的452,600-byte replay，不移除主动关闭non-range response的根因。
- **遇到non-range直接full-body drain**：可避免重开但重新失去5/3/2/1的body成本边界；本轮不采用。
- **按trace里的status/host诊断建立scheduler特判**：diagnostics只用于观测，不能成为新的policy owner。

## 验证不变量

- Range-resumable consumer-paced、non-adjacent positive target仍必须`pseudo-suspended`；
- non-range consumer-paced positive target必须出现`pseudo-retained`且不得出现policy `pseudo-suspended`；
- 随后target0必须在同一个transport open上`pseudo-resumed`/promote；
- 3/7、5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane 5+1均保持。
