# zic Implementation Plan

本文件只列未完成工作。

## P0：单帧 Bootstrap 设备闭环

- 横向动态 WebP 确认出现 `decodeRefill stage=one>0` 和 frame 0；
- 确认第一帧后出现 `mediaClassified animated=true`，随后 current 进入 c>3/c>5/c>7；
- 纵向静态邻页确认在成为 current 前完成 `one>0`、上传和首帧；
- 确认不再出现 policy 有 target=1 demand、但没有 decodeStarted 的情况。

## P0：剩余首帧性能

分别比较 source wait、native decode、output prepare 与 presentation，禁止把动态和静态 Trace 混合归因。

## P0：Flutter 与 Android 工具链

运行 analyzer、owner tests 和 Android debug/release，确认实际编译闭包。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
