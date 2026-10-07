# ADR 0329：Reader 导航状态不得拥有资源工作窗

**Status:** Accepted

## 背景

Reader 的 slider scrub、点击翻屏与绝对跳页都需要改变 viewport，但它们属于导航执行方式，不是资源 membership owner。

旧 scrub 规则把 `Interaction.scrubbing` / `Interaction.jumping` 直接解释为 current-only 或 visible-only demand：
稳定 Reader 原本持有 7/3 encoded window，进入 scrub 后会先批量 detach，再在松手后重建完整窗口。
2026-09-27 的 Profile Trace 已直接观察到这一形状：普通 idle 为 11 个 download demand，而 scrub 中间态降到 3 个可见页，
每个 preview page 又持续 detach/apply；松手后重新扩回 11。该行为可把已经加载/预热的前后页主动退出 presentation/demand 链，
表现为无限 loading、跳转后邻页冷热不一致，并制造额外 scheduler churn。

同一轮对 single-tap screen-step 的对照证明，正常窗口按真实 viewport 增量移动时只需让旧 far 退出一项、新 far 进入一项；
因此问题不是 ScrollController 本身，而是 interaction label 越权拥有了另一套资源窗口。

## 决策

- `RoleResolver` 的 resource membership 只由真实 `currentIndex`、reading direction 与 viewport coverage 决定。
- `Interaction.scrubbing` / `jumping` / `settling` 只表达输入、方向学习抑制、诊断或执行阶段，MUST NOT 单独缩小 download/decode/upload window。
- vertical 中所有真实 `visibleCoverages.fraction > 0` 的非 current 页统一提升为 `PageRole.transition`；这一规则不区分 drag、tap-step、jump 或 scrub。
- stable Reader profile继续保持 encoded 前7/后3与 decode 前2/后1。相邻 scrub preview 只按真实窗口差集增量迁移；不得做 11→3→11 的 interaction-owned teardown/rebuild。
- scrollbar scrub仍保留 ReaderController 50ms latest-wins 导航节流；该节流控制“多久推进一次 viewport”，不控制资源窗口大小。
- continuous 的 single-tap 上一/下一页使用 `requestViewportStep`：默认保留10%上下文、滚动90% viewport；动画只决定 `animateTo` 或 `jumpTo`，不得伪造 pointer/drag。
- scrollbar/绝对跳页继续使用 page-index→vertical anchor 的绝对定位语义，不通过重复 viewport-step 模拟。
- non-scrub continuous page/viewport command 不得在执行入口人工发布 synthetic `jumping/settling` demand observation；真实 ScrollMetrics/coverage 是 Pipeline 的唯一几何输入。

## 与历史决策的关系

本 ADR supersede ADR 0203 中“scrubbing current-only RoleWindow”的资源 membership 部分，以及 ADR 0227/0234/0255/0256 中仅作为当时冻结边界保留的相同假设。
这些历史 ADR 的 scrub lifecycle、cancellation、partial preservation、flow-proof 等其它结论继续有效。

## 验证

- Pipeline 回归要求 `slider scrub keeps the normal resource window`。
- 相邻 scrub 回归要求稳定 7/3 profile 的 download plan 保持 11 项，并且 current N→N+1 只 remove 1 / add 1 个 transport identity。
- continuous visible coverage 回归要求所有真实可见非 current 页为 transition foreground。
- Reader 回归要求 tap/long-press down 不产生 drag motion；continuous viewport-step 即使使用动画也不得发布 synthetic jumping/settling observation。
- Profile 真机 Trace 必须同时验证 single-tap screen-step 与 slider scrub，禁止仅凭 UI loading 文案判断资源是否稳定。

该决策不改变 NetLane 5+1、encoded 7/3、decode 2/1、50MB speculative encoded-read budget、ScrollPhysics 或 Reader 手势倍率。
