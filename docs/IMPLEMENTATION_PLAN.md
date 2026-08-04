# zic Implementation Plan

本文件只列未完成工作。

## P0：设备闭环

- 验证 startup pressure 期间 priority 400 far artifact 不获得 chunk；
- 比较 frame 0 platform presentation 到 `firstFrameReady` 的间隔；
- 验证 current decode failure 后出现 `decode-recovery`，buffered successor 持续呈现；
- 验证切页后不再播放一两帧即停滞。

## P0：staged 水位与 last keep

- 继续核对 `decodeRefill` c/n/m/p 顺序；
- 验证纵向 last output 不黑屏、last→current 自动恢复。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
