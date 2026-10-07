# ADR 0218：claim orphaning 与 admitted provider attempt 生命周期分离

- 状态：Superseded
- 版本：ZIC 0.31.0-dev.238
- Supersedes ADR 0217 中“active provider claim orphaned 即取消并 rebind”的规则；ADR 0217 的 task-scoped provider lease、strict higher-priority live handoff 与 single physical owner 继续有效。
- 被 ADR 0219 部分取代：claim orphaning 规则继续有效，但“provider consumer dispose 必然取消 attempt”改为由 transport capability 的真实 lifetime 决定。

## 背景

dev.237 的 04:46 真机 Trace 共943条事件，`active-provider-handoff`命中8次，8次全部为`providerOrphaned=true`。没有证据表明这些 attempt 的transport/source已经失效；它们只是最初 Reader generation 的 logical claim 被撤销。与此同时 physical session 已由新 Reader 的 verified-equivalent claim继续 demand，NetLane priority也会迁移。

代表性 physical transfer 已提交5,644,360 bytes并进入服务器不支持 Range 的 full-body prefix catch-up。Reader generation切换时，dev.237 因旧claim orphaned取消该attempt；取消前已重新消费1,909,680 bytes旧prefix，随后新的provider又必须从0重新做同一catch-up。visible progress没有增长是正确的，因为这部分网络字节没有形成新的committed authority。

## 决策

1. physical `DownloadSession`、writer、committed prefix仍是唯一transfer authority；active provider仍是task-scoped lease。
2. **logical provider claim detach本身不得撤销一个已经被NetLane admit且仍physically active的provider attempt。** lease可以在claim消失后短暂成为retained-orphaned；只要provider consumer/transport owner仍alive，该attempt继续执行。
3. orphaned lease期间，physical session的effective priority继续由剩余claims聚合并通过同一NetLane task迁移；旧provider transport不拥有priority policy。
4. active provider claim仍live时，另一个preferred live claim只有在priority严格更高时才允许现有dev.237 handoff；equal/lower priority不得制造provider churn。
5. provider consumer真正dispose时，其Reader-owned transport可能紧接着关闭，因此该**transport-owner disposal boundary**必须取消仍引用该consumer的active lease并等待task物理退出；若physical session仍有其它claim，退出后由普通owner调度以当前preferred exact provider重开。
6. consumer dispose只允许一个NetLane cancellation owner。收集task key用于idle barrier不得提前再cancel一次。
7. progress继续只投影authoritative `committedLength`；duplicate prefix、provider handoff或source-read字节不得计入synthetic progress。

## 非目标

- 本轮不修改full-body admission、restart-cost retention、Range/validator策略或network并发。
- 不把provider transport提升为Reader/UI状态，也不复制partial。
- 不让orphaned attempt无限越过其transport owner的真实dispose；若未来要让network attempt跨Reader transport owner存活，必须先把transport capability正式提升到composition owner，而不是绕过close barrier。
- 不把本轮Trace中的真实服务器`Range -> 200`行为伪装成可修复的Range支持。
