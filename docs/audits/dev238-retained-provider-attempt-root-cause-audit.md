# dev.238 retained provider attempt root-cause audit

## 问题清单

### 产品错误
- session切换后进度会继承physical partial，但可能长时间不增长。Trace证明progress publisher没有冻结；底层attempt在重新消费旧prefix，没有新增committed bytes。

### 性能问题
- 04:46 Trace共943条事件、`taskFailed=0`。
- `active-provider-handoff`共8次，全部`providerOrphaned=true`；没有live-provider strict-priority handoff。
- resume telemetry累计`duplicatePrefixBytes=2,237,360`，其中1,909,680 bytes来自一次`full-body-prefix-catchup-aborted`。
- 代表性physical transfer在Reader切换前已连续增长到5,602,020 bytes；claim orphaning触发cancel后才转为新provider并开始对5,644,360-byte partial做full-body catch-up。第二次Reader切换又取消该catch-up。

### 编译错误
- Trace无编译信息；当前环境无Flutter/Dart SDK，不能把Python gate当编译。

### 测试错误
- dev.237行为回归把“orphaned claim必须立即rebind”冻结成产品合同；新设备证据表明该假设过强，测试必须随新ownership结论更新，而不是保留错误行为。

## 所有权清单

| 状态/资源 | dev.237实际owner | 正确owner | dev.238处理 |
|---|---|---|---|
| physical partial / writer | composition `DownloadTransferOwner/DownloadSession` | 同左 | 不变 |
| logical demand claim | `DownloadTransferConsumer` | consumer scope | 不变；detach只撤claim |
| NetLane task priority | `NetLane` + aggregate session priority | NetLane | 不变；orphaned provider仍只迁移task priority |
| active provider attempt | `_ActiveProviderLease`，但被claim orphaning立即撤销 | 已admit physical network task | claim orphaning不再撤销 |
| provider transport lifetime | consumer/Reader transport owner | consumer直到真实dispose | 只有consumer dispose才强制cancel barrier |
| Reader progress | resolved physical `DownloadSession.snapshot` | Pipeline只读projection | 不变，不做synthetic progress |

## 被否决方案清单

- **让duplicate prefix推动UI进度**：会伪造authority，继续拒绝。
- **再次调整full-body admission阈值**：本Trace先证明是无必要provider cancel制造额外重做；不得用policy调参掩盖lifecycle错误。
- **claim orphaned立即切新provider**：dev.237设备证据已证明会丢弃有效active attempt，否决。
- **任何Reader revision都切provider**：制造transport ping-pong，否决。
- **让active task无条件跨provider consumer真实dispose继续**：当前provider transport仍可能是Reader-owned，越过close boundary会use-after-close；在transport capability正式提升到composition owner前拒绝。
- **复制physical partial到新logical session**：重新制造第二owner，拒绝。

## 结论

dev.237正确建立了task-scoped provider lease，但把claim lifecycle和transport attempt lifecycle仍绑定得过紧。dev.238只拆这一条：orphaned claim不是orphaned transport；真正的transport-owner dispose仍是硬边界。这样能保留已支付的active network work，同时不引入第二scheduler、第二partial或跨owner use-after-close。
