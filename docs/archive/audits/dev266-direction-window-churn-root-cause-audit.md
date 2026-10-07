# dev.266 浏览方向 / 3/7 window churn 根因审计

## 设备事实

输入：`zic-debug-trace-2026-08-13T12-49-14.jsonl`（dev.265）。Trace中`demandDetached=47`、`downloadPreempted=1`；大量资源退出并非NetLane destructive preemption。scrub大跳会按既有current-only规则一次detach旧窗口；普通连续翻页则按当前固定index +7/-3窗口在边界不断detach/re-add。真正的`downloadPreempted`只有一次current handoff路径，不能解释持续窗口churn。

## 源码根因

- ZIC dev.265 `RoleResolver`：forward恒为`current+offset`，backward恒为`current-offset`。
- `HeuristicPolicy._distanceDownloadPriority`：pageIndex>current固定获得“forward”较高基准。
- `AnimatedPrefetchPolicy._targetFrames`：offset +1/+2/-1固定解释为5/3/2。
- 因此“前7/后3”不是浏览方向工作集，而是三套独立的index-sign规则。向index递减方向阅读时，主要预算长期放反。
- dev.264/265在NetLane continuity上继续增加outer/near例外，只能补偿后果，不能成为方向owner。

## VibeVenera只读对照

文件库权威参考：`vibevenera-master.zip`。审查其：

- `reading_direction_predictor.dart`：单次反向只累计candidate；连续2次反向可切向；历史样本按dwell权重+指数衰减；非directional/大跳不学习。
- `preload_policy.dart`：稳定decode2/1、download7/3窗口由`direction`翻转logical offset，而不是把index符号直接等价为浏览方向。
- `pipeline_window.dart`：窗口planner只消费一个`readDirection`。
- `download_ranker.dart`：`readDistance=offset*readDirection`，rank与窗口共享同一方向事实。

该参考最重要的不是具体阈值，而是owner结构：**方向先成为有滞后的Pipeline状态，窗口/rank/waterline再统一消费它。**

## dev.266收口

1. 新增Pipeline-owned `BrowsingDirectionPredictor`，禁止Reader/NetLane复制方向状态。
2. RoleResolver、HeuristicPolicy、AnimatedPrefetchPolicy统一消费`readDirection`。
3. 删除dev.265 `protectFlowRetentionFromNormalYield`全链；next2不让槽由冻结target3自然表达，outer shallow credit<=2才可yield。
4. 保留dev.262 no-Range continuity与dev.264 cooperative fairness这两个独立transport机制。
5. 新增方向predictor、单次反向不翻转、两次反向确认、directional 3/7、directional flow credit回归合同。

## Rejected fixes

- 继续增加distance<=3/4 grace、near retention bit或取消例外：重复局部性owner。
- 一次delta立即翻转7/3：短反向会造成工作集大面积churn。
- 在NetLane判断page index/Reader方向：违反scheduler ownership。
- 扩大3/7或NetLane连接数：不能修复方向解释错误。
