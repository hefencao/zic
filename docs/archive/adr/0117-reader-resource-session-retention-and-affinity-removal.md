# ADR 0117：Reader 资源会话保留与 CPU Affinity 移除

**状态：Accepted**

## 背景

dev.132/133 增加了热字节缓存和单块 ingress，但设备 Trace `zic-debug-trace-2026-08-05T02-47-39.jsonl` 显示，每次退出 Reader 后仍销毁整个章节 Pipeline。重入时即使命中 18.3 MiB 热字节，也要把正文复制进新的 DownloadSession/native source，单次耗时约 0.7–2.87 秒。native decode 本身速度正常，dev.129/133 的 CPU affinity 没有证据支持且在设备上全部返回状态 3。

## 决策

1. `PipelineReaderSessionHost` 从 factory 获取和归还章节资源会话。
2. factory 只保留 1 个 idle 会话，TTL 2 分钟；这是资源 lease，不是 Reader UI 缓存。
3. retained 会话保留 DownloadRegistry、SourcePool、DecodeRegistry、artifact handoff、media runtime 和 workspace；释放 Reader binding、page projection、playback wake 与已使用 texture。
4. retention key 基于稳定章节/source revision 与 loader URI/revision，不依赖每次 build 重新创建的 loader object identity。
5. 同章同 revision 重入复用原 PipelineReaderSession；不同 revision、配置变化、TTL 到期或容量淘汰时完整 dispose。
6. 删除 `android_performance.rs`、`zic_prepare_decode_thread`、Dart FFI lookup 和 worker affinity 调用。Trace 的 `workerPlacementStatus` 保持字段兼容，但当前固定为 0。
7. native ABI version 保持 6，library version/build identity 更新为 `zic-media-core-dev134-abi6-lib00121400`。
8. dev.133 的默认 platform channel、单 blit lane 和普通 main-thread post 保留。

## 后果

- 返回同一章节时不再重新复制缓存正文或重建 source/cursor/session。
- idle lease 会短期保留章节级 native/临时资源，因此严格限制为 1 项/2 分钟。
- used texture 不在 lease 中，后台重入仍获得 fresh SurfaceProducer。
- 进程被系统杀死、TTL 到期或章节 revision 改变时仍走正常冷启动。

## 取代关系

- 取代 ADR 0113 中 performance-core affinity 决策。
- 取代 ADR 0116 中 affinity/cpuset 决策及“memory hit 必须重新进入新 DownloadSession”的隐含路径。
- 不取代 ADR 0116 的单 blit Android presentation 决策。
