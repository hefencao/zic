# ADR 0101：单帧 Bootstrap 与 WebP 早期权威分类

**状态：Provisional**

## 问题

dev.116 将静态页和未解析 WebP 的 decode target 设为一帧，但 staged refill 只从 `c>3`、`n>1` 等动画水位开始。`targetWatermark=1` 的 demand 因此永远不会被执行。

该缺口同时影响：

- 本地动态 WebP：本地导入曾把 WebP 初始 hint 设为静态，current 只得到一帧 demand，但没有任何 refill；
- 纵向静态 WebP：运行时确认静态后，邻页得到一帧 warm demand，但同样不执行。

## 决策

1. staged refill 在动画水位之前增加 `one>0` 阶段。
2. 所有 `targetWatermark=1`、非 terminal、depth=0 的 demand 按 priority 排序，每次只放行一个。
3. 本地 WebP 初始标记为“可能动画”，与 Mihon/Venera 保持一致；权威分类仍由 decoder metadata 决定。
4. DecodeSession 在第一帧后只要 animation metadata 已完整，就立即上报，不再等待 cursor end。
5. 动画被确认后恢复原 c/n/m/p 8/6/4/3；静态页继续保持一帧预算。

## 拒绝方案

- 继续增加静态预算：不能让从未执行的 demand 开始执行。
- 对所有 WebP 永久按动画处理：会让静态章节承担不必要水位。
- 只修本地 animatedHint：纵向静态 warm 的一帧 demand 仍会饿死。
- 等待 cursor end 才分类：一帧 target 可能在 end 之前停止 fill。

## 解除 Provisional 条件

设备 Trace 同时证明：

- 横向动态 WebP 出现 `decodeRefill stage=one>0`、frame 0、`mediaClassified animated=true`，随后进入 staged 水位；
- 纵向静态邻页在成为 current 前出现 `one>0`、frame 0 与首帧；
- 不出现 target=1 demand 长期无 decodeStarted 的情况。
