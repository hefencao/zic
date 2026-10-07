# ADR 0274：纵排 active 阶段只允许可见静态输出上传

## 状态
Superseded。ADR 0314 保留本ADR对hidden native/provisional texture active-scroll defer的设备结论，但撤销“所有hidden static presentation path一刀切defer”；external-static first-frame staging改由精确container evidence资格化。

## 设备证据
`zic-debug-trace-2026-08-15T08-15-40.jsonl` 中333条 `pageLayoutSnapshot` 的实际RenderBox extent与Reader expected extent全部一致，`extentDeltaPx=0`，采样2x2 transform保持单位矩阵，因此没有证据继续修改Sliver item extent。dev.294的`layoutResidualPx`在active阶段出现偏差，是因为probe在post-frame读取RenderBox却使用调度时捕获的旧scroll pixels；这属于观测时序错误而非layout证据。

同一Trace出现了可归因的presentation竞争：真实viewport仍在page12/13附近时，hidden static page11以`next` role触发Android presentation约24.4ms，其中blit约17.8ms；另一hidden page10约14.8ms，其中blit约10.7ms。dev.281只禁止hidden `next2` upload，因此immediate `next`仍能在active scroll占用upload/platform presentation。

## 决策
1. vertical `dragging/scrolling/settling`期间，static UploadDemand只有current、transition或真实viewport visible page可获得。
2. hidden speculative static page无论stable role是next、next2、previous或其他warm role，都defer UploadDemand。
3. 该page的DecodeDemand继续按既有decode 2/1与visible/stable-role策略保持，不通过缩decode/window来减少竞争。
4. interaction回到idle后，既有stable-role static warming恢复。
5. Reader `pageLayoutSnapshot` post-frame residual必须使用同一post-frame live scroll pixels；`scheduledScrollPixels`只用于识别capture skew。

## 不改变
encoded previous3/next7、decode previous1/next2、NetLane normal5+current reserved1、upload lane并发、dev.285 promoted retention、sourceCanvas/resident replay以及dev.293 media-aspect边界全部不变。

## 可证伪条件
下一份真机Trace若已无active hidden speculative static `uploadDemand/framePresented`而固定抖动仍明显，则本路线冻结，转current/transition output projection及external Texture/SurfaceProducer compositor；不得重新扩大到Sliver geometry、scale、下载或retention。
