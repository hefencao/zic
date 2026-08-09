# ADR 0166：Current bootstrap、执行保留槽与 Venera 物理抢占

**状态：Accepted**

## 背景

dev.182 后设备 trace 仍显示 current 首帧高度不稳定。慢页的 native decode 通常只有几十毫秒，但 `sourceWait` 可从几十毫秒扩大到数秒乃至十几秒；同一时间 `policyDecision` 经常产生 7 个 `staticWarmDecodes` 与 4–7 个 `staticWarmUploads`。这说明问题不能继续归因为 transport chunk 大小，而必须审查 policy 与执行资源所有权。

只读对照当前 VibeVenera 后发现三项结构差异：

1. Vibe 的 encoded window 为前7/后3，但稳定 decode window 只前2/后1；远页是 download-only。current 缓冲浅于3帧时，neighbor decode target 先降为0。
2. network/decode/upload 三条执行 lane 都为 current 保留一个 bounded high-priority dispatch slot；near prefetch 可以使用普通槽，但不能让页面切换排在多个长 decode/upload 后面。
3. ZIC Venera WebView 使用全局 active request identity 给 Native Network bridge 标记 requestId。旧 cancel 实现会在 JavaScript Promise 真正退出前就向 Dart 返回 cancelled，导致单 invocation permit提前转交，新旧异步 JS 有机会在同一 WebView重叠。

## 决策

### Current bootstrap

动态 current 在 holder depth 达到 `min(3, role maximum)` 前，speculative `next/next2/previous` 不启动新的 decode refill；静态 current 一帧即满足。若 current 暂时等待 source，真实已经进入 viewport 的 `transition` 可以独立取得一帧。bootstrap 完成后恢复 staged refill。

这只属于 decode refill policy，不创建 Reader startup-buffer，不控制 network eligibility。

### Static warm 范围

静态证据只能降低已经处于稳定 decode 角色 `current/transition/next/next2/previous` 的成本，不能把 `near/far` encoded-only 页面扩成 decode/upload work。真实 viewport 可见静态页可以获得一帧输出，不重新引入 `PageRole.visible`；实际内存仍由 `FrameBudgeter` 权威回收。

### Current execution reservation

保持 normal concurrency：network/decode/upload = 5/3/2。三条 lane 各允许一个 `priority >= 1000` 的 current-only reserved handoff；transition priority 900 不使用保留槽。满足 preemption threshold 40 时 current 可以请求低优先级 active work退出，但旧任务真实退出前仍占原 permit。

### Venera 物理退出

Venera 保持一个物理 JavaScript invocation context。current pressure 请求 preemption 时：

1. native 先按 requestId 中止旧 invocation 所属 HTTP connection；
2. 向 WebView 注入 `__zicCancel(requestId)`；
3. **不**立即从 `pending` 删除并向 Dart返回 cancelled；
4. 旧 JavaScript invocation 真正执行 `finally -> ZicNative.finished(requestId)` 后，native 才向 Dart返回 `runtime-request-cancelled`；
5. Dart runtime gate随后才把唯一 permit转交给最高优先级 waiter。

因此“发出cancel”与“释放单上下文permit”不再是同一个事件。

## 后果

- current 首帧不再与 far static decode/upload竞争普通执行槽。
- background prefetch仍可使用普通容量；并发基线与7/3下载窗口不缩小。
- current source等待期间不会靠 speculative neighbor decode制造额外执行噪声。
- Venera preemption可能等待旧 JS真正unwind；这是保持单上下文物理正确性的必要成本。若旧插件代码本身不可及时取消，后续应拆 request-plan/bridge阶段，而不是通过重叠两个JS invocation伪造抢占。
- dev.182 的 raw-stream/single-framing保留为 duplicate-owner清理，但不再作为首帧性能主解释。
