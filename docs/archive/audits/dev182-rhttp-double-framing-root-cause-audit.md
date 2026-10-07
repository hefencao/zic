# dev.182 根因审计：rhttp 双重 Framing 推迟 Source Growth

## 输入

- `zic-debug-trace-2026-08-09T05-38-39.jsonl`
- dev.181 唯一代码基线
- 只读 `vibevenera-master.zip`

## 设备证据

新 trace 显示 dev.181 的 production control propagation 已经工作：origin read-through存在 `controlledFallback=true`，current可携带 priority 1000 到 source path。因此本轮不再继续扩大NetLane/Venera抢占逻辑。

缓存页可在几十到数百毫秒首帧，未缓存慢页仍主要由 `sourceWait` 主导；多次current startup的 source wait约2秒到十余秒，而native decode通常只有几十毫秒。说明decoder/texture不是统一的首播数量级瓶颈。

## VibeVenera 对照

权威参考实现中，Reader streaming transport调用 `ImageDownloader.loadComicImage(... streamOnly: true)`。`images.dart` 的64 KiB startup / 256 KiB continuation coalescing只用于非direct-stream路径；direct stream直接把rhttp chunk送入后续streaming transport。

ZIC dev.179却在 `RhttpSourceResourceDirectTransport`增加同样的64/256 KiB聚合，而 `DownloadJob`早已有：

- `BytesBuilder(copy: false)`；
- startup flush target 16 KiB；
- 首次flush后改为 `sourceProgressQuantumBytes`（64 KiB）。

于是 production发生双重framing。trace中的source length也常呈约65 KiB后直接跃迁到约328 KiB的形态，符合额外256 KiB transport门槛。

## 修复

- 删除 `RhttpChunkCoalescer` 实现与专用测试。
- rhttp媒体前缀验证完成后直接yield底层stream chunk。
- 唯一聚合owner恢复为 `DownloadJob`：16 KiB startup，随后64 KiB source-progress quantum。
- dev.179 release gate迁移为禁止transport-level coalescer，并检查DownloadJob单一owner。
- 新增dev.182 gate，防止64/256 KiB transport buffer重新出现。

## 未改变

- Reader encoded 7/3、decode 2/1、network/decode/upload 5/3/2。
- receiving-retention与current pressure preemption。
- dev.181 `ArtifactCacheTransport` controlled read-through。
- Venera单 invocation context及request cancellation。
- rhttp 0.18.0、range/validator、media prefix与response abort语义。

## 后续判别

若dev.182后current `sourceReady/firstFrame`明显提前，说明双重framing确为首帧延迟组成部分。若source growth已变为16/64 KiB而`openMicros/sourceWait`仍稳定秒级，则下一轮只拆Venera request-plan/runtime与HTTP response-open时间，不再回到framing/窗口/decoder。
