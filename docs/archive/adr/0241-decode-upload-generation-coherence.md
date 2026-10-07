# ADR 0241：Decode/Upload physical-generation 依赖一致性

状态：Accepted

## 背景

UploadSession 并不是独立 frame owner；它在创建时绑定一个具体 DecodeSession，并从该 DecodeSession 的 FrameHolder claim 待上传帧。只要 DecodeSession 实例不变，这个引用关系是正确且高效的。

dev.262 真机 Trace 暴露了一个代际边界：physical download owner 被替换时，Reader 的 source watch 会识别 `physical-generation-changed` 并失效旧 DecodeSession。但 UploadSession 没有同步失效，于是 retained UploadSession 仍引用已 dispose 的旧 DecodeSession。新的 DecodeSession 能正常解出 depth=7，旧 UploadSession 却继续看到旧空 holder，最终页面长期 `waitingFrame`。

## 决策

1. physical-generation rebind 继续只由 `LiveCoordinator._watchSource()`识别；Reader/widget 不新增 generation owner。
2. `UploadRegistry`提供按 DownloadId 的依赖失效操作；它只退休 UploadSession/output，不管理 source、cursor 或 transport。
3. rebind 顺序固定为：
   - cancel 同 DownloadId 下 demand-owned decode/upload lane task；
   - invalidate UploadSession；
   - invalidate DecodeSession；
   - 由仍存在的 demand/source wake 正常重建 DecodeSession，再由 decode frame-ready 唤醒并创建新的 UploadSession。
4. 必须先失效 upload 再 dispose decode，因为 UploadSession 的生命周期依赖具体 DecodeSession 实例。
5. 不让 UploadSession 在每次 prepare 时自行查询/切换 DecodeRegistry 实例。跨 generation 偷换依赖会让旧 output/playback/present claim 的归属模糊；generation change 应是显式退休与重建。
6. source rebind trace记录 `invalidatedUploads` 和 `invalidatedDecodes`，用于验证依赖传播，而不是据此驱动策略。

## 被拒绝方案

- **UploadSession prepare 时发现空 holder 就无限 retry**：旧 session 永远不会看到新 DecodeSession，retry 只制造空转。
- **强制 decode 重填**：Trace 已证明新 decode depth=7，问题不在 decode 供给。
- **widget/page key 重建**：会把 pipeline generation bug推给UI，并可能制造第二个 lifecycle owner。
- **重新下载资源**：physical artifact 已 promoted/full，既浪费网络也无法修复 stale DecodeSession pointer。

## 验证不变量

- 发生 `physical-generation-changed` 后，旧 UploadSession 不得继续存在于 UploadRegistry。
- 新 generation 首次 decode frame ready 后，UploadRegistry 必须创建绑定新 DecodeSession 的 session，并可以再次 `frameUploaded/firstFrameReady`。
- 没有 generation change 时，不额外 evict output，不破坏既有 retained/static/last-frame 生命周期。
- 3/7、body 5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane normal5 + current reserved1保持冻结。
