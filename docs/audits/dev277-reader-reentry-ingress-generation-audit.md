# dev.277 Reader re-entry / ingress generation 根因审计

## 设备事实

基于 `zic-debug-trace-2026-08-14T07-54-24.jsonl`：

- 本地 page0 第一次 mount 约80.143s，`firstFrameReady`约80.598s（454,498µs）；退出后第二次 mount 约83.128s，约2.182s后 dispose 时仍 `firstFrameReady=false`。
- 第二次进入并非文件读取或decode失败：physical generation rebind明确记录 `invalidatedUploads=1, invalidatedDecodes=1`；artifact memory cache提供完整5,906,374 bytes，`sourceReady`后decode最终达到depth=7。失败集中在upload：多次priority1000 `uploadStarted`，没有新的 `frameUploaded/firstFrameReady`。
- 第一次退出前同 logical upload identity仍有活跃动画upload；旧 UploadSession generation invalidation如果延迟 `uploader.release(DecodeId)`，可在新 generation session创建后由旧async tail释放同一logical slot。
- 网络 page216 在新 Reader 中复用 retained response并完成约16.0MiB physical body；Reader late join先发布约5.58MiB playable prefix，随后 projection attachment failure 使后续decode持续报告 source failure/0-length，页面最终无首帧。

## 源码根因

1. `DownloadIngressProjectionRegistry.get(session)` 仅按DownloadId返回existing projection，绕过了 `attach(session)` 已实现的 DownloadSession object identity generation检查。
2. Artifact promotion 在 `partial.rename(finalPath)` 与 `_state=promoted` 之间存在合法owner-internal窗口；旧 Reader replay只按 `_state` 选择partial/final路径，可能在rename后读取已不存在的partial并得到空stream。
3. synchronized replay旧闭包只验证physical revision/epoch/length；没有同时证明 projection 自己真的追平 targetLength/sealed/failure，因此存在把不完整Reader-local source加入live fan-out的语义缺口。
4. `UploadSession.dispose()` 对 pending prepare复用 ordinary detach 的 deferred uploader release。generation replacement允许新 UploadSession立即使用同一logical DecodeId，旧async tail迟到的 `release(id)` 可退休新 generation slot。

## dev.277 收口

- registry `get()`统一使用generation-aware attach。
- Artifact read owner新增partial/final open fallback并返回已打开file handle，消除exists→open TOCTOU；Reader/sessions不感知rename状态。
- synchronized late join在live fan-out前同时验证physical boundary与projection snapshot闭合。
- generation dispose立即退休 uploader slot并禁止old tail二次release；ordinary detach仍保留deferred release。
- 新增storage/session/upload回归合同，覆盖promotion rename窗口、same-id physical generation和pending upload dispose。

## 未改变

不修改网络窗口、水位、NetLane、transport lease、partial retention、resolver cache、Venera runtime并发或current优先级。该轮只闭合 Reader-local generation / Artifact read / uploader retirement owner。
