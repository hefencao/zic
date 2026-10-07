# ADR 0094：分阶段解码水位与 last output 保留

**状态：Provisional**

## 背景

dev.109 设备 Trace 已恢复 Android platform presentation，但首次进入 Reader 的首个可见页面仍约 1.4–1.7 秒才报告 `firstFrameReady`。Trace 还显示页面 15 在页面 14 成为 current 后被 `demand-detached`，即使它仍是纵向布局中的重叠旧页，导致上半屏回到黑色 loading。

固定的 current=2、neighbor=1 只能描述单次目标，不能表达消费波动和 batch decode。直接把所有角色同时提高水位又会制造启动拥堵。

## 决策

1. 角色窗口增加 `last` 与 `next2`。last 是上一次 current，不占用独立的 previous/next 槽位。
2. last 只保留既有 upload output：取消 pending/active upload、暂停 playback、保留 present claim，不继续 download 或 decode refill；重新成为 current/transition 时恢复 playback。
3. decode target 仅作为上限，runtime 每次只选择一个 staged refill：
   - c>3；n>1；m>1；p>1；
   - c>5；n>2；
   - c>7；n>3；m>2；p>2；
   - n>5；m>3。
   阈值为严格水位，batch 可以自然超过目标。
4. 拖动中的 transition 是逻辑 n，不建立额外 transition 水位。
5. DecodeSession 每产出一帧立即唤醒 upload，同时继续补当前 staged target；首帧显示不等待整批 refill 完成。
6. 同一页面只允许一个 in-flight presentation。第一帧先发布，期间到达的新帧只标记 pending，完成后追到最新帧，不能通过 generation 递增使首 Surface 永远被后续帧作废。
7. current、transition、last output 受 frame budget 保护；last decoded successors 不受保护。

## 所有权

- 角色与最大需求：`pipeline`。
- staged refill、last freeze/resume 与 output budget：`sessions`。
- 首 Surface 串行发布：`pipeline_runtime`。
- Reader Presentation 不拥有水位、decode holder 或 upload session。

## 拒绝方案

- 同时把所有页面补到固定高水位：扩大启动拥堵。
- last 继续下载/解码：与 `l=keep` 语义冲突。
- 仅在纵向 Widget 层缓存截图：形成第二套 output 生命周期。
- 等完整 c batch 后再呈现 frame 0：增加首帧延迟。

## 解除 Provisional 条件

设备 Trace 出现 `decodeRefill` 和 `lastFrameKept`；首次 Surface 在 frame 0 presentation 后立即报告；页面切换时旧 current 不再 `demand-detached`；纵向重叠区域不再黑屏；首 12 帧与快速切页无新增 stall。
