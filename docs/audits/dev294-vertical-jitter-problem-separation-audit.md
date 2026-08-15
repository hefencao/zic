# dev.294 纵排抖动问题分离与实际布局观测审计

## 用户纠正
本轮没有新的设备 Trace。权威新增事实来自用户对上一轮结果的明确纠正：dev.293 后缩放异常已经解决，仍未解决的是抖动。此前 NEW_CHAT_PROMPT 把“scale 仍在”写成当前问题，因此后续诊断入口错误。

## 为什么不能继续改 media-aspect
`MediaAspectViewport(fitWidth)` 在 dev.293 已从 direct parent fill 改为 source-aspect-preserving `FittedBox`，且用户设备结果确认对应 scale signature 消失。继续修改 sourceCanvas、predecode、resident replay 或 FittedBox 将重新打开已闭合路线，同时无法解释“比例正常但固定区域仍抖”。

## 剩余候选层
现有设备闭环已分别处理 active geometry snapshot、idle correction、retained texture reuse、vertical hidden-target 和 promoted physical hot retention。若抖动仍存在，最需要区分的是：
1. 逻辑 `ReaderVerticalGeometry` 稳定，但 Sliver 实际 child constraints/size/transform 在 active scroll 中变化；
2. Sliver 实际 box 稳定，但 current/transition/visible role 对同一 output 的 presentation subtree/texture transform 变化；
3. Flutter box 与 projection 都稳定，但 external Texture / SurfaceProducer / compositor 出现 frame-time 或 transform 抖动。

## dev.294 实现审计
- `ListView.itemExtentBuilder` 与原 page extent 保持不变；probe 位于既有纵排 page box 内部，不创建第二套 extent。
- 每个纵排 page 使用稳定 GlobalKey 取得该实际 RenderBox；仅真实 visible coverage 进入采样。
- ScrollStart/ScrollEnd 强制采样；ScrollUpdate 最快约每 100 ms 一次，每次最多记录 8 个真实可见 page，避免逐帧日志。
- `pageLayoutSnapshot` 包含 expected start/extent、constraints、render size、extent delta、paint bounds、global rect、transform 2x2/translation、DPR、stitch、role、interaction 与 revision；另记录 `layoutResidualPx = globalTop + scrollPixels - expectedStart`，消去正常滚动位移后直接暴露 page placement/transform 抖动。
- DebugTrace 对该事件使用 scroll 250 ms 导出桶并为关键数值保留 min/max；错误/lifecycle 语义不变。
- 该事件没有任何读取方进入 policy/geometry/presentation，纯属调试观测。

## 下一次真机判据
在已知固定抖动区域同时观察 `readerObservation`、`pageLayoutSnapshot` 与 `framePipelineTiming`。不要仅凭肉眼再次修改几何：先看抖动时 `extentDeltaPx`、global rect 或 transform 是否同步变化；若均稳定，再转 output projection / compositor，而不是扩大资源窗口。
