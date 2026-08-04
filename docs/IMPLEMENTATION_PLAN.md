# zic Implementation Plan

本文件只列未完成工作。

## P0：低性能设备大 WebP 启动闭环

- 确认首帧前 current local `bucketLimit=1`、`bucketActive<=1`；
- 确认首个 platform texture `textureLeaseReused=true`、`surfaceReconfigureCount=0`；
- 确认首帧后 queued local task 原位恢复 `bucketLimit=2`，active DownloadSession 不重启；
- 比较 source wait、decode dispatch/native、output prepare、present 与 mount-to-first-frame；
- 以约 400 ms 为目标继续优化，但不得通过缩小 7/3、降低稳定并发或低分辨率假首帧掩盖瓶颈。

## P0：Patch 交付闭环

- 从 dev.123 干净基线验证 `git apply --check --index` 和实际 apply；
- 对比 apply 后树与 dev.124 正式树；
- ZIP、patch 与 SHA 一并交付，patch 路径读取 `.zic-workspace.json`。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android release 与目标设备 Trace。
