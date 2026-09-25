# 2026-09-24 vertical static ratio rebuild scope audit

## 触发

用户继续报告竖排静态滚动抖动，并要求先评估 Widget rebuild，不调整 Pipeline policy。输入设备 Trace 为 `zic-debug-trace-2026-09-24T10-46-35.jsonl`。

## Device-observed

- Trace 共约 4,479 条事件；媒体分类 37/37 为 static。
- 本轮样本中 task failure、fallback、legacy retry、surface reconfigure 均为 0，没有证据要求重开 Pipeline failure/recovery 路线。
- 2,170 个非零 ScrollUpdate interval 中，1,299 个 <10ms、653 个 14–18ms、12 个 >=35ms；现象更像滚动期周期性额外 UI/layout 工作，而不是持续算力不足。
- active forward scroll 中 source-canvas ratio 依次到达 page35–40，并触发 `pageGeometryPrepared`；reverse scroll 的 page23/22、30/29/28/27 等还需要既有 `geometryCorrectionTarget` 保持 incoming-prefix anchor 连续。

## Source-inspected root cause

`ReaderRuntimeScreen` 已把 page dimension 更新按 frame 合并进 `pageAspectRatios` ValueNotifier，并对近似相同比例去重；adaptive classifier 也只在 profile 真变化时 `setState`。放大器在 `ReaderView`：

1. `_handlePageAspectRatiosChanged()` 每次拿到新的 ratio map 都调用 `_adoptPageAspectRatios(... rebuild: true)`。
2. 旧实现无论该 map 只是进入 `_pendingVerticalLayoutRatios`，还是只改变 visible tail 之外的 future extent，最后都执行 `setState(() {})`。
3. `_pageSlots` 虽已缓存，所以 page media composition 不会重建，但整个 `ReaderView.build -> LayoutBuilder -> vertical ListView` 仍会重新执行。连续静态预解码发布 source-canvas size 时，这会把独立页面的 header/geometry 事实放大成 whole-Reader build work。

这与既有 dev.280/dev.287 的几何合同并不冲突：active prefix 仍需冻结，future page 可提前采用真实 extent，reverse incoming prefix 仍需原子 geometry correction。问题是 **失效范围过大**，不是 ratio/geometry owner 错误。

## 边界与修改

- 不修改 encoded 7/3、decode 2/1、UploadLane、FrameBudgeter、NetLane、static warm、output retention 或任何 Pipeline policy。
- 保留 `ReaderView` 为 vertical presentation geometry owner，不建立第二份尺寸/缓存 authority。
- 新增 Reader-local `_verticalLayoutRevision`，只包住 vertical `ListView` geometry subtree。
- pending-only ratio 事实若没有改变 `_verticalLayoutRatios`，不触发任何 Widget rebuild。
- decode-ahead / idle commit 确实改变 extent 时，仅递增 local revision，重建 ListView geometry subtree；ReaderView 根、控制面和 cached page shells 不被 ratio 通知弄脏。
- reverse prefix 的 `geometryCorrectionTarget`、idle top-pixel anchor、viewport/DPR/stitch 既有合同全部保留。

## Toolchain-verified

- `flutter test packages/reader/test/reader_navigation_test.dart`: 24/24 通过。
- 新回归 `live vertical ratios rebuild only when ListView geometry changes` 直接走 runtime 使用的 `pageAspectRatiosListenable`：
  - pending-only update 后 ReaderView 根与 ListView 均保持同一 Widget 实例；
  - future extent 真变化后 ReaderView 根保持同一实例，仅 ListView 实例更新。
- dev.280、dev.281、dev.287、dev.294、dev.308 focused gates 全通过。
- `flutter analyze --no-fatal-infos` 无 error/warning；仅保留既有 info 级 deprecation/style 提示。
- `tool/check_repo.py` 与 `tool/check_documentation.py` 通过。

## 未验证

本轮没有把 debug trace 的 interval 数字升级成性能结论。是否显著降低用户可见抖动仍需在包含本修改的 fresh Profile/Release 真机滚动中复验；若局部 rebuild 已闭合而抖动仍存在，应按既有 scene/compositor 边界继续归因，不得以此为理由扩大或缩减 Pipeline 资源窗口。
