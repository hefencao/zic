# dev.246 根因审计：current destructive-preemption burst

## 输入

- 唯一代码基线：dev.245完整包。
- 真机Trace：`zic-debug-trace-2026-08-12T12-15-21.jsonl`。

## 问题清单

- 编译错误：Trace无新编译错误证据。
- 产品错误：快速跨页/跨session时大量active final-image transport仍被current取消，只有部分连接保留。
- 性能问题：67次`downloadPreempted`全部incoming=1000；30个victim已有partial，committedLength合计约246.7MiB、正值中位约8.3MiB、最大约16.6MiB。Trace另有4次`full-body-prefix-catchup-aborted`，说明取消会直接扩大重复prefix流量。
- 测试错误：dev.245历史gate将victim-side 200ms demotion grace视为current production形状，dev.246需版本感知而不得恢复旧控制流。

## Trace事实

67次preempt只形成28个相邻间隔<=50ms的burst，39次是burst内额外cancel，最大一组66ms内连续cancel 6条；另有一组约8.4ms内连续cancel 5条，victim已有约6.5–9.0MiB partial。`pageCurrent`共210次，间隔中位约10.6ms、75%约27.0ms、85%约88.4ms、90%约594.2ms，呈明显快速scrub/停稳双峰。17/28个preemption burst在100ms内current再次改变，合计覆盖46/67次cancel。

只有5/67个victim记录了非零`restartCostBytes`；这是因为该事实只描述不可恢复full-body catch-up投入，而不是普通可Range-resume partial。故“把所有committedLength当sunk cost提高到current-safe ceiling”既语义错误，也会重做dev.202已经否决的headroom保护。

## 所有权清单

- semantic demand rank：Pipeline policy。
- normal/reserved admission、pending排序、preemption资格、victim选择与cancel token：唯一属于NetLane。
- physical partial/writer：DownloadSession/DownloadTransferOwner。
- provider URI/transport task lifetime：已admit physical task lease。
- Reader只提交observation并消费双进度，不得决定preemption dwell或直接cancel final-image transport。

## 被否决方案

- 继续把200ms改成300/500ms victim demotion grace：保护对象错误，无法处理已rank0较久但被瞬时current反复杀死的task。
- 把所有committed partial字节计入restart-cost：普通Range可恢复partial不是取消后必须重付的成本，会恢复dev.202式headroom退化。
- 禁止current preemption：会重现current无法抢占。
- 扩大normal并发或增加多个永久reserved slot：违反既有network=5+bounded current handoff，不解决destructive decision抖动。

## 决策

破坏性抢占改为incoming candidate稳定100ms + single in-flight preemption；free/reserved admission即时，victim仍由统一rank决定。
