# ADR 0108：启动 Current 前缀独占与精确 Output 预热

**状态：Provisional**

> dev.125 修订：`.zic-workspace.json` 改为机器本地配置，不进入发行 ZIP 或生成 patch；环境变量 `ZIC_PATCH_DIR` 可覆盖。后台恢复与 partial failure 见 ADR 0109。

## 问题

低性能设备 Trace 中，Reader 首帧 `mountToFirstFrameMicros=1600616`。current 与 next 两个 20 MiB 左右的 `content://` WebP 在进入 Reader 后同时占用 local bucket；current 首帧等待 3 MiB 前缀，`sourceWaitMicros=243900`。首帧 output 另有 `outputPrepareMicros=248001`、`presentMicros=224919`、`surfaceReconfigureCount=1`，且 texture lease 未复用。

原 output prewarm 使用来源画布尺寸；实际 uploader identity 使用对齐后的 `DecodeTarget.physicalWidth/physicalHeight`，因此预热可能创建错误尺寸 texture，首帧仍在临界路径创建和重配置目标 surface。

## 决策

1. output prewarm 始终使用 Pipeline 已附着的最终 `DecodeTarget`，不再使用来源尺寸。
2. 当 current 是 local bucket 且尚无已呈现 output 时，本会话 local bucket 临时限制为 1。current 首个 platform present 完成后立即恢复 profile 的稳定值 2。
3. 临时限制通过既有 `NetLane` bucket 元数据实现，不创建启动下载器；active DownloadSession 不重启。释放门控后，`LiveCoordinator.refreshDownloadScheduling` 只重新提交既有 demand，使 queued task 原位迁移 bucket limit。
4. remote bucket、全局 5 槽、7/3 窗口和 current handoff 语义不变。remote current 不限制 local bucket。
5. 门控按“首个 output 已真实 present”释放，不等待动画达到 7 帧水位；失败、dispose、current 变化或 Reader detach 也必须释放。
6. Trace analyzer增加启动期 local active/bucket limit、首帧 texture reuse、surface reconfigure 与 mount-to-first-frame 指标。
7. 发布必须包含完整 ZIP、SHA-256 和可由 `git apply --index` 应用的基线 patch；patch 目录读取根目录 `.zic-workspace.json` 的 `patch_dir`。

## 所有权

- local/remote bucket 稳定值与页面窗口：`pipeline_runtime` profile。
- 动态启动门控与 Reader current/output 生命周期投影：`pipeline_runtime/PipelineReaderSession`。
- queued task 的原位重调度：`sessions/LiveCoordinator` 与既有 `NetLane`。
- texture lease 和精确尺寸预热：现有 platform media runtime。
- patch 交付配置：仓库根工作区配置与 release tooling；不进入 App runtime。

## 拒绝方案

- 永久把 local 并发降为 1：会损害首帧后的预下载。
- 取消 7/3 或关闭 next 下载：掩盖启动竞争并破坏既有产品合同。
- current 首帧前创建第二套本地直读器：会竞争 DownloadSession/transport 所有权。
- 使用来源画布预热后让 uploader 缩放复用：texture identity 不匹配，仍需重配置。
- 以 decode 深度大于 4 才恢复 local=2：首帧已显示后仍不必要地阻塞预下载。
- 声称本轮已达到 400 ms：当前环境不能执行 Android 真机验证。

## 解除 Provisional 条件

在目标低性能设备确认：首帧前 local bucket active 最大值为 1，首个 texture lease 被复用、surface reconfigure 为 0；首帧后 local bucket 恢复 2；`mountToFirstFrameMicros` 显著下降且无同 key 双 writer、重启或预下载退化。
