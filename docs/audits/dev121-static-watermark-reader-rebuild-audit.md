# dev.121 静态水位与 Reader 局部更新审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.120_directed-prefetch-source-wake.zip`。
- 用户反馈：预加载表象已改善，但 dev.120 的定向 wake 方向仍掩盖了静态页一帧即可满足水位的基本语义；纵向静态阅读偶发回拉，低性能设备 build+layout 接近 30 ms。

## 代码事实

- `HeuristicPolicy` 在权威静态分类后通常生成 `targetWatermark=1`，但 classification callback、Pipeline replan 与 LiveCoordinator refill 可存在短暂时序差。旧 demand 仍可能保留 current 的高水位。
- `StagedDecodeRefillPolicy` 只依据 demand target、holder depth、terminal 和 source eligibility；已呈现静态 output 不在满足条件中。
- `ReaderRuntimeScreen` 使用 `AnimatedBuilder(reader)` 包住整个 Scaffold；`ReaderView` 内部再次用 `AnimatedBuilder(controller)` 包住整个 LayoutBuilder。
- 每次纵向中心页变化都会 `ReaderController.notifyListeners()`，从而重建两层 Reader 树和 ListView/PageView。页面 active/keep-alive 实际只影响少数已挂载 host。
- 纵向 item extent 在同一次 build 中反复创建 `ReaderVerticalGeometry`。

## 实现

- refill policy 增加通用 `satisfiedOf`；LiveCoordinator 将“权威单帧且 holder/output 合计一帧”投影为满足。
- `_decodeNeedsFill` 同样执行该判断，避免 force/source-wake 绕过 policy 后重复 fill。
- ReaderView 移除根级 controller AnimatedBuilder；ReaderRuntimeScreen 不再用 reader AnimatedBuilder 包裹整个 Scaffold，控制栏分别监听。
- 新增 page-local shell，仅 active、keep-alive、rotation 变化的已挂载页面 setState。
- 纵向单次 build 共享 geometry 快照。

## 风险与未验证

- 当前环境没有 Flutter/Dart SDK，新增 owner tests 未实际执行。
- 局部 rebuild 应降低 build/layout，但具体 30 ms 长尾与偶发回拉仍需同设备 Trace/DevTools 复验。
- 页面尺寸异步更新仍可能触发 anchor correction；若 dev.121 后仍回拉，应依据新的 frame/build evidence 单独审计 anchor restore，而不是恢复整树 rebuild。

## 拒绝方案

- 不拆分静态/动画状态机。
- 不删除定向 source wake；它解决的是 source event 执行机会，与水位满足语义不同。
- 不通过缩小 7/3、降低动画水位或关闭 ratio 更新掩盖滚动问题。
