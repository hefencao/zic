# dev.175 Venera current transport 与下载卡顿根因审计

## 唯一基线与证据

- 代码基线：`zic_v0.31.0-dev.174_current-preemption-saturated-handoff.zip`
- 设备 Trace：`zic-debug-trace-2026-08-08T23-53-24.jsonl`
- 只读对照：文件库无后缀 `vibevenera-master.zip`

## 结论

`dev.174` 的 NetLane admission/preemption 本身已生效。Trace 中 current 可直接以 `priority=1000`、`globalActive=6`、`handoffActive=1` 进入 reserved handoff；但多个 current 在取得 network handoff 后仍在 `source-loader` 等待约 3–8 秒。因此剩余等待不再位于 NetLane，而位于 source request-plan / Venera 单上下文调用链。

VibeVenera 将同一个 `CancelToken` 从 pipeline task 贯穿到图片 loading config 与网络 request。ZIC 在 `DownloadJob -> Transport.open()` 处丢失 NetLane token，导致 Venera request-plan 进入独立 FIFO；即使外层 prefetch 已被抢占，runtime 内仍可能继续占用唯一 JavaScript 请求上下文。

下载卡顿有独立的直接证据：Trace 的 `bytesCommitted` 出现约 13 ms、17 ms、34 ms 的 `nativeIngressMicros` 尖峰。native `zic_cursor_decode_next()` 当时在整个 WebP decode/scale/composite 期间持有 `ByteSource` 读锁，而 Dart UI isolate 上的 `zic_source_reserve/commit` 需要写锁，因此后台 decode 能反向阻塞前台下载 append。

## 修改

- 新增 scheduler-owned `TaskControl`，由 `CancelToken` 提供 cancellation + 动态 priority；`DownloadJob`、LoaderTransport、source transport、catalog source 与 runtime adapter逐层透传。
- Venera 保持单 invocation；runtime gate由 FIFO permit transfer改为优先级感知 transfer，并在 controlled active invocation被取消时调用既有 `cancel(requestId)`。
- controlled request-plan不复用另一 task 的 in-flight Future；非 Reader/uncontrolled路径继续保留原 coalescing。
- host direct request建立后接入 task cancellation，真实 request退出前不提前释放 lane permit。
- native WebP decode拆成 `prepare_next` 与 `decode_prepared`：前者在 source读锁内复制单帧压缩 fragment，后者在锁外执行解码、缩放、合成与 canvas copy。
- 不调整 7/3 encoded窗口、2/1 decode窗口、5/3/2 lane与 current priority。

## 拒绝方案

- 不增加 Venera runtime并发；其单 JavaScript请求上下文语义保持不变。
- 不缩小预下载窗口或降低线程数来掩盖主 isolate锁等待。
- 不在发出 cancel时提前从 active计数释放 permit。
- 不把 current 特判塞入 UI/Reader；priority仍由 NetLane唯一拥有。
