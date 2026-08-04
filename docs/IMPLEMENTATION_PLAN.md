# zic Implementation Plan

本文件只列未完成工作。

## P0：纵向真实可见 Demand 设备闭环

- 向上和向下拖动时，确认相邻页 coverage 刚大于 0 即进入 transition demand；
- 对比 page host mount、decode/upload demand、firstFrameReady 与 dispose 时间；
- 确认拖动未跨中心时不再长期显示伪 loading；
- 检查快速反向拖动时 target/last 不抖动或误释放。

## P0：静态输出内存预算

- 采集 `staticWarmDecodes`、`staticWarmUploads` 和 FrameBudget 回收；
- 用不同分辨率静态章节验证 96 MiB 推测预算与 128 MiB 实际预算；
- 确认内存充足时保留更多 previous/next/last，一旦超限优先回收远端静态 output；
- 继续确认动画 staged c/n/m/p 水位不受静态策略影响。

## P0：剩余首次加载长尾

- 比较 direct ingress、texture lease reuse、outputPrepare 与 mount-to-first-frame；
- 继续定位首次进入而非重进的 Surface/host 发布延迟；
- 检查静态与动画章节差异。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
