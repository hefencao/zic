# zic Implementation Plan

本文件只列未完成工作。

## P0：staged 水位与 last keep 设备闭环

- 验证 `decodeRefill` 顺序符合 c/n/m/p 阶段；
- 验证 `lastFrameKept` 出现，旧 current 不再 `demand-detached`；
- 验证 last→current 自动恢复播放；
- 验证纵向重叠上半屏不再黑屏。

## P0：首帧闭环

- 比较 frame 0 platform presentation 与 `firstFrameReady`；
- 确认首帧 upload 在 c refill 完成前启动；
- 检查前 12 帧 native decode、channel dispatch 与 schedule queue。

## P0：重进 coordinator dispose

- 继续定位约 5.67 秒 coordinator dispose 长尾；
- 区分 active decode、upload present、lane idle 和 session registry 清理。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
