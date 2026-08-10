# ADR 0181：full-body catch-up 的跨 demand defer 记忆与两级成本门槛

## 状态

Accepted。Supersedes ADR 0180 的单一 `>=1 MiB / priority>=820` admission 与仅当前 demand 生命周期 defer 语义；ADR 0176/0177 的 playable-partial authority、Range continuity proof 与 response reuse继续有效。

## 新证据

`zic-debug-trace-2026-08-10T08-46-42(1).jsonl` 是 dev.199 真机 trace。45 条 origin `sourceRead`累计约245.59 MiB，`resume*`报告的 `duplicatePrefixBytes`约40.96 MiB（16.68%）。其中22.10 MiB在current=1000路径发生，属于用户当前页必须支付的不可Range full-prefix证明；18.86 MiB从priority=820启动。

820重复流量里，单个约9.14 MiB partial先在next=820启动，追赶约5.09 MiB后因需求离开而abort；后续又在next=820重新启动并完整重复约9.14 MiB。仅这一very-large partial就在820路径产生约13.57 MiB重复。该页面在trace内没有升到transition/current，因此把所有`>=1 MiB`都视为“820可承担”过于宽松。

另一个dev.199缺口是defer记忆被`_retireDownloadTracking()`随demand detach清除。同一约5.43 MiB DownloadId在三个独立previous=780 demand窗口分别发生Range probe→HTTP200→defer；约11.95 MiB DownloadId也发生两次。5次重复defer的host-open墙钟累计约3.68s。它们没有读取full body，但重复消耗request-plan/connection和NetLane/runtime槽位。

## 决策

1. `NetLane`继续是唯一网络lane/rank/preemption owner；本ADR只调整sessions对“已确认需要full-body”的成本admission，不增加Reader/Pipeline gate或bandwidth scheduler。
2. full-body catch-up按authoritative `committedLength`分两级：
   - `<1 MiB`：任意现有download demand可继续；
   - `1 MiB <= partial < 8 MiB`：保持dev.199，dynamic priority `>=820`可继续；
   - `partial >=8 MiB`：只有真实visible transition/current，dynamic priority `>=900`才可继续。next=820保留已有playable partial，但不为不可Range的大前缀从0重读。
3. validatorless Range probe本身仍先执行。只有服务器已经返回200、即本attempt必须full-body时才应用成本门槛；支持206的endpoint继续最多64KiB continuity proof，不受该门槛影响。
4. defer记忆改为`DownloadId -> deferredCommittedLength`。同一LiveCoordinator内，demand detach/re-add不得仅因为tracking retire就遗忘；如果重新出现的低优先级demand面对**相同 committedLength**，不得再次probe/open。
5. defer记忆不是“endpoint永不支持Range”能力：只要 committedLength变化，旧记忆失效；只要priority达到当前长度对应的admission门槛，也必须清除defer并重新probe，使新路由/endpoint仍有机会返回206。
6. session promoted/disposed、成功完成或coordinator dispose时必须清理defer记忆。低优先级detach只允许保留与当前idle partial长度完全匹配的defer项。
7. admission继续只读取scheduler-owned dynamic priority与authoritative committedLength。endpoint hash、HTTP version、`duplicatePrefixBytes`、decode/playback状态不得成为policy输入。

## 后果

- previous/next2在多次离开/重新进入窗口时不会为同一未增长partial反复打开已知高成本fallback probe。
- 1–8 MiB中等partial仍保留next=820预取价值；>=8 MiB very-large partial已具有大量playable bytes，只有页面真正进入transition/current才承担整段重读成本。
- current=1000的必要full-prefix重复不会被隐藏；下一份trace应把“可避免背景重复”与“当前页不可Range成本”分开看，而不是追求`duplicatePrefixBytes=0`。
