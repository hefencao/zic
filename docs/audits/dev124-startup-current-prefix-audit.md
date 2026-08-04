# dev.124 大 WebP 启动路径审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.123_current-download-handoff-vertical-composition.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-04T12-47-46.jsonl`。
- 只读参考：VibeVenera Pipeline；未修改或合并参考工程。

## 问题清单

### 编译

- 本轮输入未提供新的编译错误。

### 产品与性能

- Reader page 12 的 `mountToFirstFrameMicros` 为 1,600,616。
- current 与 next 在 27.6/27.8 ms 同时启动，均为 local bucket、`bucketLimit=2`；current 需要 3 MiB 前缀才产生首帧。
- current 首个 source-ready 为约 257.9 ms；首帧 decode 的 source wait 为 243.9 ms。
- 首帧 decode 为 409.686 ms，其中 native 225.175 ms、worker dispatch 183.940 ms。
- 首帧 output prepare 为 248.001 ms，platform present 为 224.919 ms；texture 未复用且发生一次 surface reconfigure。
- 首个 host frame-ready 为约 1.6006 s。

### 工具与交付

- dev.123 交付没有 baseline-to-release patch。
- 仓库没有持久化 patch 输出目录，无法稳定生成用户可直接 `git apply --index` 的命令。

## 所有权清单

| 能力 | 所有者 |
|---|---|
| current/next 页面 demand、7/3、稳定 bucket cap | `pipeline` / `pipeline_runtime` |
| 动态启动 local gate | `pipeline_runtime/PipelineReaderSession` |
| transfer/session/partial | `sessions/downloads` |
| queued task bucket 元数据刷新 | `sessions/LiveCoordinator` |
| texture prewarm/lease | platform media runtime |
| patch_dir 与 release artifact | repository workspace tooling |

## 根因判断

1. local bucket 的稳定并发 2 对持续预下载合理，但在首个大 WebP 只需要尽快取得可解码前缀时，current 与 next 同时读取同一 SAF provider，扩大首个 3 MiB 的到达时间。
2. output prewarm 使用 `PageAsset.width/height`，而实际输出使用对齐后的 DecodeTarget；尺寸不一致导致预热 lease 无法命中。
3. 首帧 texture 创建/重配置与平台 schedule 留在关键路径。该结论由 `textureLeaseReused=false`、`surfaceReconfigureCount=1` 和 248/225 ms 的 output/present 证据支持。
4. 400 ms 是设备验收目标，不是本轮静态实现可以证明的结果。native/dispatch 时间仍需下一份 Trace 复核。

## 修改

- current local 首个 output 前：local bucket 动态为 1；真实 present 后恢复 2。
- remote current 不触发该门控；全局/remote 5、7/3、handoff 不变。
- exact DecodeTarget output prewarm。
- release 时原位刷新 queued task，不重启 active transfer。
- 增加启动 Trace analyzer、owner/static tests、工作区 patch 配置和 release patch 合同。

## 否决方案

- 永久 local=1、缩小窗口、关闭 next、复制 VibeVenera 私有下载器、Reader 自建本地读取路径、先显示错误尺寸 texture 后二次缩放。
