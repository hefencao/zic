# dev.176 根因审计：Current host open长尾与下载卡顿

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.175_venera-transport-native-ingress-preemption.zip`
- 设备trace：`zic-debug-trace-2026-08-09T00-33-35.jsonl`

## Trace结论

- 3099条事件；current仍能以 `priority=1000/globalActive=6/handoffActive=1`进入NetLane handoff，说明dev.174 admission/preemption仍生效。
- origin `sourceRead.openMicros`继续出现约5.18s、8.22s、8.30s、8.86s、17.74s、19.28s等长尾。多个旧下载在调度层很快进入 `Failure(cancelled)`，但其 origin stream稍后才以 `completed:false`结束，说明response body终止晚于调度状态。
- `nativeIngressMicros`相比dev.175前显著下降；本trace `bytesCommitted.maxNativeIngressMicros`中位约60us、p90约205us。剩余artifact commit单次常见约2–5ms、最大约6.4ms，主同步CPU已主要来自partial append的Dart CRC32。
- 唯一真实network `taskFailed`是远端连接接收中断；不需要新增retry owner。

## 代码根因

- `_prefetchEncodedMediaBody()`只在prefix准备期间监听 `TaskControl.whenCancelled`；返回 `_PrefetchedHttpResponseBody`后取消监听失效。wrapper async*结束时也没有强制取消底层 `StreamIterator<HttpClientResponse>`。
- `Artifact._append()`在每个下载commit同步 `_crc.add(bytes)`，使多路远程prefetch持续占用UI isolate。

## 修复

- prefetched response body在完整生命周期监听scheduler cancel并执行 `abort()`；wrapper stream非自然完成时在 `finally`取消底层iterator。
- partial append只写文件/推进长度并标记checksum dirty；seal/restore通过 `Isolate.run`读取文件并计算最终CRC32。
- 增加response-stream取消与deferred-CRC行为测试，以及无Dart环境可执行的dev.176静态gate。
