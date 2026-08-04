# zic Implementation Plan

本文件只列未完成工作。

## P0：本地资源路径设备闭环

- 确认 local bucket active 不超过 2；
- 确认完整本地响应 `artifactWriteMicros=0`；
- 比较跳页后的 source wait、native ingress 与首帧；
- 确认本地读取不再显示下载进度。

## P0：纵向全部可见页闭环

- 确认 observation 上报全部视口交叠页；
- 确认额外 visible 静态页在进入视口时已有一帧 output；
- 确认可见页不再因普通 current 切换被 `demand-detached`；
- 观察保护 output 超过预算时的真实内存峰值。

## P0：Flutter 与 Android 工具链

运行 analyzer、owner tests 和 Android debug/release，确认实际编译闭包。

## P1：来源能力配置

在保持全局 5 的前提下，为不同远程漫画源暴露独立 bucket cap；本地并发是否从 2 调整必须以设备吞吐为依据。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
