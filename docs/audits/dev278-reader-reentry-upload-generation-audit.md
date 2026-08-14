# dev.278 Reader 二次进入 Upload/Decode generation 根因审计

## 设备事实：08:31 Trace

- 第一次 page0 mount 正常，约208ms出现`firstFrameReady`。
- Reader短期retention后第二次mount，`readerSessionReused`仍保留3个decode session和1个upload session。
- page0重新解析physical owner时记录`physical-generation-changed`，且`invalidatedUploads=1`、`invalidatedDecodes=1`。
- 本地artifact立即命中完整5,906,374 bytes；source随后ready/sealed。
- replacement decode逐步产帧，最终frame6时depth=7。
- upload在新一轮最早进入`waitingFrame`；此后虽反复有coordinator `uploadStarted`，UploadSession从未记录`uploading`，也没有`frameUploaded`，页面约5.11s后退出仍无首帧。第三次进入同型失败，约2.22s退出。

## 排除

这次失败不支持继续修改以下层：

- 下载/Artifact：current完整bytes已经存在并完成sourceReady。
- decode吞吐：当前decode明确达到depth=7。
- platform uploader性能/slot等待：`UploadSession`在真正调用`FrameUploader.upload()`前会先发布`uploading`，本Trace没有该状态。
- dev.277旧generation延迟`release(DecodeId)`：新Trace中rebind失效计数正确，而症状停在取得frame claim之前。

## Owner缺口

`UploadRegistry`以logical `DecodeId`缓存`UploadSession`，而`UploadSession`内部保存concrete `DecodeSession`对象。dev.263/277依靠LiveCoordinator rebind顺序退休依赖，但registry自身没有验证“缓存UploadSession所绑定DecodeSession是否仍为DecodeRegistry当前对象”。因此一旦两registry的concrete generation出现漂移，logical id仍命中，upload可永久读取retired/empty holder，同时另一个current DecodeSession正常产帧。

## dev.278收口

将concrete dependency invariant放回UploadRegistry：`get()`总是先取得current decode；identity一致才复用，identity不一致则先dispose旧upload再创建replacement。外部rebind invalidation仍保留作为正常主路径；registry identity check是owner自身的最后一致性边界，而不是新的retry或selector。

## 下一Trace判据

二次进入应满足：physical rebind → fresh decode/source wake → decode frame available → UploadRegistry使用current concrete decode → `uploading` → `frameUploaded` → `framePresented` → `firstFrameReady`。若仍失败，优先新增/检查concrete generation诊断，不回下载层。
