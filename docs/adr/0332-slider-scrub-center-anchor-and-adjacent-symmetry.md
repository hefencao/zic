# ADR 0332：Slider scrub center anchor 与相邻 presentation 对称

状态：Accepted

## Context

ADR 0330/0331 已把 slider scrub 的 resource membership、execution depth、真实 visible transition 和静态 presentation deadline 分开。
真机继续暴露两个独立但相互放大的问题。

第一，continuous slider 是绝对 page-index 导航，但 scrub 期间和 pointer-up 后采用了两种不同 geometry anchor。
held scrub 的 source ratio 以 selected page center 修正 ScrollPosition；
尚未提交的 prefix ratio 却在 pointer-up 后走 ordinary idle top-pixel anchor。
2026-09-28 Profile 复现中，thumb held 在 47%，current=82/logical=82.5；
release 后 scrollPixels 从约 75549.63 改到 74784.19，current 变为83，thumb 显示48%。

第二，scrub 故意不学习 readDirection，因此 stable direction 保持 +1 是正确的。
但 transient static deadline 仍继承稳定阅读优先级：next 820、next2 800、previous 780。
向前或向后拖 slider 时，previous 都会排在 next2 后面。
本例 local preparation 有两个 slot，但增加 slot 不是语义修复：即使改成三个，
current/next/next2 仍会先占满，previous 依旧最后。

## Decision

1. Vertical slider 的最终整数 page index 在整个 scrub transaction 内是显式 geometry anchor。
   pointer-up 只结束 input phase，不得把 anchor 从 selected-page center 切换为 viewport top。
2. scrub 中已知的所有 prefix ratio（index <= selected anchor）必须立即进入 vertical layout，
   因为任一 prefix extent 都会改变绝对 page-index 的物理 offset。
   同时，任何新暴露的 visible page 若 ratio 已经可用，也必须在 held scrub 的后续 layout pass 消费，
   不得等待另一个 dimensions event 或 pointer-up。
3. 若 pointer-up 时仍有 pending ratio，首次 idle commit 继续用同一个 selected-page centered offset。
   layout/coverage 收敛后才释放 scrub anchor。普通 content drag/scroll 继续使用既有 top-pixel continuity。
4. transient static deadline 中 immediate next 和 immediate previous 是 slider target 的对称 ±1 representation deadline。
   两者使用相同 local preparation / one-frame decode / upload priority；next2 保持更低。
   该对称只属于 transient scrub presentation，不改变 stable 7/3 readDirection、方向学习或动画水位。
5. 不增加 worker 数，不新增 scheduler。local preparation 仍为2，decode/upload/presentation 各自保留既有限额，
   NetLane 继续唯一拥有网络调度，localOnly 仍不能开启 remote source。

## Evidence

修复前 backward scrub 可见 local-preparation 顺序为 1000 / 820 / 800 / 780，
对应 current / next / next2 / previous，且 release 会发生 47% -> 48% 的 thumb/current 漂移。

修复后的 Profile 双向实测：
- backward held/release：8% -> 8%，selected current 不变；
- forward held/release：49% -> 49%，selected current 不变；
- transient local preparation 变为 1000 / 820 / 820 / 800；
- 可见相邻首帧样本中 prev n=18 median/p90/max=48.8/82.3/98.3ms，
  next n=17 为47.4/76.7/80.5ms，不再存在固定 previous 落后一个 next2 阶段的结构偏置；
- 两次长 held scrub 均在 pointer-up 前得到相邻 firstFrameReady，且 taskFailed=0。
