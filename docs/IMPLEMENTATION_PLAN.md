# zic Implementation Plan

本文件只列未完成工作。

## P0：全局下载并发设备闭环

- 验证 `downloadStarted.globalActive` 始终不超过 5；
- 验证 local 与不同 remote `sourceId` bucket 的 active 数不超过来源上限；
- 快速跨多页时确认退出窗口任务被取消，新窗口按唯一 priority 启动；
- 比较 scheduler wait、first chunk 和完整 stream 的 p50/p95。

## P0：WebP 增量解码闭环

- 验证 partial source 的 `decode-prefix` 按 local 1 MiB / remote 256 KiB 增长；
- 验证同一 page/frame 重进后复用最小充分前缀；
- 分离 `partial-source` 与 `sealed-source` failure；
- 若 sealed failure 持续，扩展 native 错误原因，而不是继续增加 chunk。

## P0：播放与 last keep

- 继续验证 staged refill、切页恢复、纵向 last output 与首帧发布；
- 检查整体播放恶化是否随旧窗口任务取消而消失。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
