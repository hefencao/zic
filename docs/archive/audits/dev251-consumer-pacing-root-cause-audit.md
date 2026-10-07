# dev.251 根因审计：unsupported flow-control fallback

## 输入
- 唯一代码基线：dev.250完整包。
- 真机Trace：`zic-debug-trace-2026-08-12T16-42-06.jsonl`。

## 问题清单
- 编译错误：无新编译错误证据。
- 产品错误：不支持真实stream pause的source body会绕过动画frame credit并继续完整消费。
- 性能问题：Trace有35次真实paused、22次resumed，说明direct主路径已工作；9/9 current preemption victim此前均处于flow-paused状态，证明paused连接仍占NetLane槽，但该连接池问题不与本轮伪pause混改。
- 测试错误：dev.249/250 gate把`streamBackpressure`固定写死为唯一flow capability，需要版本感知而不能恢复旧形状。

## 所有权清单
- 动画frame target：Pipeline policy。
- response pause能力事实：transport `ByteResponseFlowControl`。
- frame边界与pause执行：sessions `DownloadJob`。
- scheduler/连接permit：NetLane，本轮不修改。
- artifact-cache/resident：本地已拥有字节，不参与伪网络pause。

## 被否决方案
- 对所有`flowControl=none`一律等待：会把artifact-cache/resident本地读取也占住NetLane槽。
- 用source名称判断是否伪pause：能力泄漏且不可维护。
- pseudo pause通过cancel/reopen/Range模拟：重建连接并增加重复prefix。
- 本轮顺便把paused task排除5路计数：没有resume permit仲裁会在多task同时恢复时突破并发上限。

## 决策
增加typed `consumerPacing`，只由已知安全的source body声明；DownloadJob统一消费真实/伪两种flow mode并保持task/response连续。
