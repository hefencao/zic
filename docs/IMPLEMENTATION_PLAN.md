# zic Implementation Plan

本文件只列未完成工作。

## P0：纵向静态预加载设备闭环

- 确认 page source ready 后在进入视口前产生 `decodeRefill`、frame 0 与 output；
- 确认预加载页不会因另一个 waitingSource current/neighbor 阻塞；
- 确认静态页退出 upload demand 后出现 `staticFrameKept`，而非立即 `demand-detached`；
- 确认只有 FrameBudget 超限时才出现 `pageOutputReleased reason=frame-budget`；
- 对比上下滑动时的可见 loading 与 page host dispose。

## P0：本地动态图路径设备闭环

- 确认 local bucket active 不超过 2；
- 确认完整本地响应 `artifactWriteMicros=0`；
- 比较跳页后的 source wait、native ingress 与首帧；
- 确认本地读取不再显示下载进度。

## P0：Flutter 与 Android 工具链

运行 analyzer、owner tests 和 Android debug/release，确认实际编译闭包。

## P1：来源能力配置

在保持全局 5 的前提下，为不同远程漫画源暴露独立 bucket cap；本地并发是否从 2 调整必须以设备吞吐为依据。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
