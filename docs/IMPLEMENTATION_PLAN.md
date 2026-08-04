# zic Implementation Plan

本文件只列未完成工作。

## P0：direct durable ingress 设备闭环

- 确认 cache-hit `bytesCommitted.cacheResident=true` 且 `artifactWriteMicros=0`；
- 比较 current source-ready、native ingress、完整 source stream 与 mount-to-first-frame；
- 验证 resident stream 中断后 session reset 并可重试；
-确认 origin、partial 和 resume 仍正常写入并 promotion。

## P0：Android texture pool 设备闭环

- 首次进入确认真实尺寸预热与 source/decode 并行；
- 快速重进确认 `textureLeaseReused=true`；
- 比较 frame 0 `outputPrepareMicros` 与 Surface reconfigure；
-检查 last/transition present claim 是否阻止 lease 过早归还。

## P0：decode wake 去重

- 比较逐帧 timing 与 `decodeRefill` 数量；
-确认 waitingSource 只在首个 source、64 KiB 增长、seal、failure 或 demand revision 变化时重提；
-继续区分 partial needMoreData 与 sealed cursor/native failure。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
