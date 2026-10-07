# ADR 0256：UploadRegistry 拥有 concrete DecodeSession generation binding

状态：Accepted（dev.278）

## 背景

08:31 dev.277 真机 Trace 中，本地 page0 第一次进入 Reader 正常；第二次进入时 physical generation rebind 已明确记录 `invalidatedUploads=1`、`invalidatedDecodes=1`，artifact 重新提供 5,906,374 bytes，decode 随后达到 depth=7，但 upload 从 `waitingFrame` 起始后始终没有进入 `uploading`，更没有 `frameUploaded`。第三次进入重复。

`UploadSession._prepareNow()` 只有在其绑定 `DecodeSession.holder` 为空时才会保持 `waitingFrame`；一旦取得 frame claim，会在调用 platform uploader 前先切换到 `uploading`。因此该 Trace 排除了网络不足、decode未产帧和platform upload耗时作为这一失败的直接阻塞点。

## 决策

`UploadSession`继续在构造时绑定一个具体 `DecodeSession`，生命周期内不得动态换绑。`UploadRegistry`作为UploadSession lifetime owner，必须同时拥有这条依赖的generation一致性：

1. `get(id)`先通过`DecodeRegistry.get(id)`取得当前concrete DecodeSession。
2. 若缓存UploadSession不存在，按既有方式创建。
3. 若存在且`identical(existing.decode, currentDecode)`，直接复用。
4. 若logical DecodeId相同但concrete DecodeSession不同，先从registry移除并dispose旧UploadSession，再创建绑定currentDecode的replacement。
5. `prepare()`继续只经`get()`进入，因此任何真正upload work都不能绕过该检查。

这不是让UploadSession“寻找最新DecodeSession”。generation切换仍通过显式retirement/recreation表达；旧session的pending work由其自身generation barrier收口。

## 保持不变

- `LiveCoordinator` physical-generation rebind仍先invalidate upload，再invalidate decode。
- ordinary detach/reset/frame-budget仍保留既有deferred uploader release语义。
- previous3/next7、body 5/3/2/1、decode 2/1、holder 7/5/3/2、normal5+current reserved1不变。
- 不修改下载、NetLane、Venera、缓存容量，也不增加retry/grace/清缓存/重下载补偿。

## 验证

新增Dart回归：人为让DecodeRegistry替换同logical DecodeId的concrete DecodeSession而保留旧UploadSession；再次`UploadRegistry.get()`必须dispose旧UploadSession并返回绑定replacement DecodeSession的新session。当前远程环境若缺Dart/Flutter，只能由静态contract gate确认测试与owner代码存在，不能宣称Dart测试已执行。
