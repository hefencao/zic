# dev.180 根因审计：工具链回退纠正与 Previous 预下载错位

## 输入
- `zic-debug-trace-2026-08-09T04-18-30.jsonl`
- 用户本地 Flutter 3.44 / OpenJDK25 的 Pub、AGP、Gradle构建结果
- 只读参考：权威 `vibevenera-master.zip`

## Trace结论
trace共6208条事件。页面窗口策略持续生成约11个download demand，说明7/3没有整体停止；问题发生在稳定页切换后的角色归属。

current 104→105 时，新policy decision仍报告11个downloads；previous current对应active download发生`1000→0 retained-background`；同一时刻另一active download发生`0→780`成为previous。源码对照显示previous current被写为`PageRole.last`且backward slot显式跳过last，因此immediate previous被吞掉，后一页错误递补为previous。

所以症状不是NetLane/current抢占失败，而是presentation keep与relative resource role错误共用互斥enum。

## VibeVenera对照
VibeVenera稳定窗口仍是download前7/后3、decode前2/后1；offset -1先参与previous/decode，上一输出keep独立于相对位置。不能只给last补priority，否则会在大跳页制造冗余下载。

## 修复
- RoleResolver相对role map移除last占位/跳过，新增独立`retainedIndex`。
- 相邻旧current恢复真实`previous/next` download/decode。
- HeuristicPolicy叠加upload-only last-output retention。
- PipelineController把retainedIndex纳入replan identity与trace。
- 相邻回归锁定previous priority780+decode+last upload；大跳回归锁定detached retained页无download/decode。

## 工具链纠正
- workspace直接`test`收回`^1.25.0`。
- 恢复AGP9.3.1、Gradle9.5.0、compileSdk37。
- Gradle daemon criteria改OpenJDK25；Android Java/Kotlin bytecode继续17。
- dev.179 gate移除被本轮取代的AGP/Gradle/JDK版本绑定；dev.180 gate锁住JDK/bytecode分离与previous/retention模型。

## 未改变
current preemption、receiving retention、5+1 handoff、Venera pressure-only抢占、rhttp0.18与64KiB/256KiB framing、encoded7/3、decode2/1、holder7/5/3/2及lane5/3/2均不变。
