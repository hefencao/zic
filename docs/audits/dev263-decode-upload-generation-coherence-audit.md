# dev.263 根因审计：physical-generation rebind 后 UploadSession 仍绑定旧 DecodeSession

## 设备事实（11:13 dev.262 Trace）

- page98 的 download identity `identity:<3638c8469146939b,177>` 在 25.191562s 发生 `reader-source-watch-rebind / physical-generation-changed`。
- page97 的 download identity `identity:<-5168cb309e96887e,178>` 在 25.872447s 发生同类 rebind。
- page97 对应 decode/upload identity `identity:<7ac5dad9ea068a43,212>` 随后在 31.408660s 已从新的 source 解到 frame 0..6、`depth=7`、`sourceLength=13,345,582`、`sourceSealed=true`。
- 同一 identity 从 31.415093s 起反复 `uploadStarted`，但没有后续 `uploading/frameUploaded/framePresented`；43.818061s 再次进入 `waitingFrame`，44.072974s 又启动 upload，仍无首帧。
- page97 的 physical download 同期已经 `local-completion-short-circuit state=promoted committedLength=13,345,582`，因此“打不开”不是网络缺失，也不是新 DecodeSession 没有帧。

## 根因

`LiveCoordinator._watchSource()` 在 physical generation 改变时会 `DecodeRegistry.invalidateForDownload()`。该调用会 dispose 并移除旧 `DecodeSession`；后续 decode demand 会创建新的 `DecodeSession` 并正常产帧。

但 `UploadRegistry` 没有同步失效。`UploadSession` 又在构造时永久保存一个具体 `DecodeSession` 引用。因此旧 UploadSession 会继续查看已经 dispose 的旧 decode/holder。新的 DecodeSession 即使已经 depth=7，旧 UploadSession 仍只能得到空 holder，表现为 `uploadStarted -> waitingFrame`，页面永远没有新的 `firstFrameReady`。

这解释了为何只有发生 physical-generation rebind 的“部分图片”在回访后打不开，而其他页面正常。

## Issue / authoritative owner / rejected fixes

- Issue：physical source generation 的依赖失效只传播到 DecodeRegistry，没有传播到依赖 DecodeSession 实例的 UploadRegistry。
- authoritative owner：`LiveCoordinator._watchSource()` 仍是 physical-generation rebind 的协调点；`UploadRegistry.invalidateForDownload()`只负责按 DownloadId 退休其持有旧 DecodeSession 的 upload/output session。
- 生命周期顺序：先 cancel 同 identity 的 decode/upload lane task，再 invalidate upload sessions，最后 invalidate decode sessions；后续 demand 由 registry 正常重新创建依赖链。
- rejected：重新下载、强制 decode refill、提高 holder 水位、增加 upload retry、在 Reader widget 层重建 key、让 UploadSession 动态跨代寻找另一个 DecodeSession。这些都绕过或模糊 generation dependency owner。

## dev.263 修改

- `UploadRegistry` 增加 `invalidateForDownload(DownloadId)`，按 download identity dispose/remove 依赖旧 DecodeSession 的 UploadSession。
- source-watch rebind 时同时 cancel decode/upload lane；按 `upload -> decode` 顺序失效依赖链。
- rebind trace 增加 `invalidatedUploads` / `invalidatedDecodes`，真机可直接确认失效传播。
- 扩展既有 `logical source watch rebinds after aliased physical owner retires` regression：旧 physical generation 先完成 decode+upload，退休后同 logical page 绑定新 physical generation；要求第二次 upload 使用新 UploadSession 并再次产出 output。
- 不修改 3/7、5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane 5+1，也不改变 dev.262 non-range response continuity。
