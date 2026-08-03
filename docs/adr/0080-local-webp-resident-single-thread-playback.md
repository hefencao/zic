# ADR 0080：本地 WebP 常驻双 worker 与帧内单线程播放

- 状态：Accepted
- 版本：`0.31.0-dev.96`
- 日期：2026-08-03
- 取代/修正：ADR 0078 中 cursor 归零后关闭 worker 与 libwebp `use_threads=1` 的部分；保留 ADR 0078 的 handle-only handoff、持久 demux 与 Pipeline 所有权。ADR 0079 的 target-canvas 几何继续有效。

## 背景

设备 trace 已表明单次 native 解码并非唯一瓶颈。dev.95 仍在首次页面使用时创建两个 Dart decode isolate，并在最后一个 cursor 释放后关闭；transition 升级为 current 时，same-key demand 使用 replace 取消不可中断 native decode/upload，完成后的有效帧被当作过期结果丢弃。与此同时，libwebp 帧内线程与两个 isolate 形成嵌套并发，Android/Flutter 又重复处理 Surface geometry 与 alpha 预乘。

## 决策

1. `bridge` 拥有两个进程期常驻 Dart decode isolate。App composition 在 `runApp` 前显式等待同一 `NativePipelineMediaRuntimeFactory.prewarm()` 完成，构造 factory 也保留幂等预热，cursor 只拥有 native cursor，不拥有 worker pool 生命周期。
2. worker pool 使用 current/非 current 双队列。两个 worker 中最多一个执行非 current；另一个槽始终可供 current。页面角色由 `sessions` 通过可选 `ScheduledFrameCursor` 能力下传，Reader 不接触 worker 或 lane。
3. libwebp advanced decoder 固定 `use_threads=0`。播放并发只来自两个常驻 Dart isolate；不安装 `WebPSetWorkerInterface`，不新增 `webp_worker.rs` 或 8 线程 persistent native worker pool。
4. libwebp 锁定 v1.6.0 / commit `4fa21912338357f89e4fd51cf2368325b59e9bd9`。`tool/prepare_webp.sh` 在独立 prepared tree 自动应用 `libwebp-vp8-thread-buffer-pool-v1.6.0.patch`。补丁只在每个 OS decode 线程保留一份最大 VP8 workspace，不创建工作线程。
5. same-key transition→current 的 changed decode/upload 使用 lane `follow`：正在执行的不可中断任务完成并保留结果，然后按最新 demand 跟进。真正 removed identity 仍取消和释放。
6. current decode watermark 为 2，保留两个后继帧；transition 为 1。7/3 下载窗口、2/1 页面预解码窗口、current/transition 上传和 5/3/2 lane 不变。
7. `media_core` 以 libwebp `MODE_rgbA` 生成预乘 RGBA并完成 target-canvas blend/dispose。Android blit 只逐行复制，SurfaceProducer 只在创建或尺寸变化时配置 Surface；Flutter fallback 不再二次预乘。
8. 流式 source 增长且 demux metadata 未完成时立即刷新 descriptor snapshot。小于 8 px 的 source/target 使用精确 contain 尺寸，不用 8 px 对齐下限放大。
9. 本地文件与 Android DocumentFile 顺序 ingress 使用 1 MiB 分块；普通网络 transport 仍使用 256 KiB。

## 被否决方案

- 8 线程 libwebp persistent worker interface：会与两个 Dart isolate 叠加并发，放大线程和内存压力。
- 缩小预取窗口、关闭 successor 或降低 lane：掩盖 identity/生命周期错误。
- transition→current 取消 native work：丢弃有效帧并造成纹理抖动。
- Android/Flutter 二次预乘或每帧重设 Surface：重复所有权与重复工作。

## 后果

- factory 构造会幂等启动 native workers；App 启动在 `runApp` 前等待同一 prewarm future。库加载错误由启动诊断记录，也可由测试直接观察。
- worker 与 TLS VP8 workspace 持续到进程/线程结束，以稳定页面重进延迟换取有界常驻内存。
- libwebp 补丁必须随精确上游 pin 更新；升级版本时补丁应用失败应阻止构建，而不是静默跳过。
