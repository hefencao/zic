# dev.293 纵排媒体比例边界审计

## 触发
用户在 dev.292 真机继续报告“缩放不正常，需要稳定后才正常”。

## Trace 结论
`zic-debug-trace-2026-08-15T05-01-31.jsonl` 中 pipeline-reader-1 共观察到 8 个 `pageDimensionsResolved`，全部为 `basis=sourceCanvas / source=physical-ingress-source-canvas`，证明 dev.291/292 source metadata/replay owner 已真实命中，而不是继续 raster fallback。page18–22 首次 current 相对尺寸解析分别约晚 0.884s、1.346s、2.948s、5.543s、5.325s；并非窗口来不及。sourceCanvas 与 decodedRaster 的 aspect 相对误差约 0.000–0.032%，不足以解释明显视觉尺度变化。

## 源码审计
纵排 stitched 页面由 `ReaderVerticalGeometry` 按 viewport width × source height/width 给出 item extent。`LocalImagePlayer` 的 `MediaAspectViewport(fitWidth)` 却存在历史 shortcut：已知尺寸时不再做媒体 fit，而直接 `builder(BoxFit.fill)`；Android `NativeTextureViewport(fill)` 再让 external Texture 无条件占满父盒。此路径把“父 sliver box 每一帧都绝对精确”提升成媒体比例正确性的前提。

这一前提已被设备现象反复证明过于脆弱。dev.286 曾通过第二套 presentation extent/OverflowBox 试图保证父盒正确，但随后被 source-metadata owner 问题否证并 supersede。继续让 Presentation 依赖父盒精确会把任何 future Sliver/layout 问题直接表现成图像拉伸，污染诊断。

## dev.293 收口
- 删除 `fitWidth -> direct BoxFit.fill` shortcut。
- 已知 source dimensions 时统一经过 `FittedBox`；`fitWidth` 对齐改为 `Alignment.topCenter`。
- renderer 内部仍 fill fitted source box，因此 texture/image renderer 不各自复制 aspect 逻辑。
- 不创建第二套 page extent，不改 Reader geometry、anchor、window、decode/upload、texture 或 download owner。
- dev.291/292 physical ingress/replay 修复保留，因为新 Trace 已证明其 sourceCanvas 命中真实有效；但它们不再被宣称是 scale defect 的唯一根因。

## 下一次设备判据
1. active scroll 中图像 width-fit 尺度应保持稳定，不应在 idle 时突然“恢复比例”。
2. 即便 item extent 暂态不匹配，也只能在页面尾部观察到裁切/留白，不能看到图像纵向拉伸。
3. 若仍有尺度变化，立即冻结尺寸/predecode/replay/media-aspect 路线，转 Sliver layout / Texture compositor / current-transition projection。
