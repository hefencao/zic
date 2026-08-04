# ADR 0111：启动缓冲 Staged Refill 闭包

**状态：Provisional**

## 问题

dev.126 在首帧后建立启动缓冲，但 current 的第一次 staged refill 只从 `c>2` 补到 depth 3。若目标深度为 4–7，任务结束时 `_wakeNextDecodeRefill(except: id)` 会排除刚执行的 current；与此同时启动缓冲又将其他页面设为暂不可参与 refill。没有下一候选，也没有新的 observation/source 事件保证再次唤醒 current，导致 `playbackBuffering waiting` 永久不闭合。

## 决策

1. 普通 staged refill 结束后仍默认不重复选择同一 DecodeId。
2. 若下一 decision 与刚完成的 DecodeId 相同，且该 UploadSession 仍处于 startup buffering，则允许为同 key 提交 follow task，继续下一水位阶段。
3. UploadSnapshot 首次进入 `ready + startupBuffering` 时，Pipeline runtime 定向调用 `refreshDecodeScheduling(..., only: id)`，覆盖 upload 在 decode batch 结束之后才建立 buffering 的竞态。
4. 同 key follow 由既有 DecodeLane 去重；不会并行创建第二个 DecodeSession 或 cursor。
5. 达到 startup target 后 UploadSession 发出 `ready`，current-only eligibility 解除，原有邻页 refill 自动恢复。
6. 长期 7/5/3/2、水位阶段、首帧立即显示和约 250 ms 启动目标保持不变。

## 所有权

- staged refill chaining：`sessions/LiveCoordinator`。
- startup state：`sessions/UploadSession`。
- upload snapshot 到 decode 调度的组合桥：`pipeline_runtime`。
- 水位定义仍由 `sessions/StagedDecodeRefillPolicy` 拥有。

## 否决方案

- 不把目标 4 降成 3 来适配第一档水位。
- 不通过 4 ms playback ticker 周期扫描 decode 状态。
- 不删除启动缓冲或恢复无缓冲播放。
- 不重新引入 visible-page decode 补丁。
- 不新建 startup 专用 lane 或第二套队列。

## 解除 Provisional 条件

真机 Trace 中每个 `playbackBuffering waiting` 均在对应 current demand 生命周期内闭合为 `ready`；current 按需连续出现 `c>2 → c>4 → c>6`，不存在 outstanding buffering，邻页在 ready 后恢复 refill，动画持续播放。
