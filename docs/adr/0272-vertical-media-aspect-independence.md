# ADR 0272：纵排媒体比例独立于 Sliver 暂态 extent

## 状态
Accepted，supersede ADR 0067 / ADR 0265 中“continuous fitWidth 的父 page box 始终精确，因此媒体可直接 BoxFit.fill”的局部实现合同；不撤销其余 stitched/geometry 所有权结论。

## 设备证据
05:01 dev.292 Trace 已经完成对前几轮尺寸路线的关键否证：page18–22 的 `pageDimensionsResolved` 均为 `basis=sourceCanvas / source=physical-ingress-source-canvas`，在首次成为 current 前约 0.9–5.5 秒已经存在；对应 sourceCanvas 与 decodedRaster 的 height/width 差仅约 0.00–0.03%。用户仍观察到 active scroll 期间尺度异常、稳定后恢复。因此继续扩大 previous1/next2 decode、继续前移 source metadata 或继续修改 resident replay 都缺乏因果依据。

## 根因边界
`ReaderVerticalGeometry` 拥有纵排 item extent、prefix、anchor 与 navigation geometry；媒体 presentation 不应反向拥有这些值。但历史优化把 `MediaAspectViewport(fitWidth)`直接转换为`builder(BoxFit.fill)`，等价于假设父 sliver 在每个 paint frame 都已经是精确 source aspect。任何 active-scroll 暂态 layout/extent 差异都会因此变成媒体本身的纵向拉伸，并在 idle/layout 收敛后突然恢复，形成“缩放不正常，稳定后正常”的视觉签名。

## 决策
1. Reader 继续唯一拥有 item extent/navigation geometry，不新增 presentation extent，也不恢复 dev.286 `presentationExtentAt`/`OverflowBox`。
2. `MediaAspectViewport` 对已知尺寸的任何 fit 都保留 source-aspect fitting；`fitWidth` 使用 top-aligned `FittedBox(fitWidth)`，内部 renderer 只 fill 已按 source aspect 建立的 fitted source box。
3. 父 extent 若暂时错误，只允许媒体在 trailing edge 被裁切或留下空白；不得通过 `BoxFit.fill` 把错误 parent aspect 写进图像比例。
4. `NativeTextureViewport(BoxFit.fill)` 仍是合法底层 primitive，因为它现在只应填充已经由上层 media aspect boundary 构造的等比 source box；不把 texture_bridge 变成 Reader geometry owner。
5. previous3/next7、decode previous1/next2、NetLane、upload/texture/retention 参数均不改。

## 可证伪条件
若 dev.293 真机仍出现同样的尺度变化，则 source metadata/predecode/media-aspect 路线冻结；下一阶段只审 Sliver 实际 layout metrics、Texture layer constraint/compositor 以及 current/transition output projection，不再扩大窗口或恢复视觉补偿。
