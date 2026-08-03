# ADR 0083：前帧端到端耗时与本地 artifact ingress


> dev.100 修正：`platformUploadMicros` 同时包含 platform queue，当前 `platformOtherMicros` 必须再扣除 `platformQueueMicros`；`decodedToUploadMicros` 也已拆为 intentional lead 与真实 backpressure。

- 状态：Accepted
- 版本：`0.31.0-dev.99`
- 日期：2026-08-03

## 背景

设备上的本地 Animated WebP 在前几帧仍会停顿数秒。dev.98 trace 只能分别看到 `frameDecoded`、`frameUploaded` 和 `framePresented`，且导出会按 1 秒窗口合并这些高频事件。单次 frame 无法跨 decode lane、常驻 isolate、native demux/libwebp、upload lane、Android Surface copy、主线程结果派发和最终 present 关联。

同一 trace 还显示 promoted artifact 以 256 KiB 分块进入 DownloadSession：5.7 MiB 文件产生 22–23 次 Dart stream 唤醒，18–21 MiB 文件产生约 70–80 次唤醒。这与本地文件 1 MiB 分块合同不一致。

## 决策

1. `bridge` 在 process decode pool 中分别记录：worker pool ready、worker slot queue、isolate round trip、native decode、native metadata 和 worker index。worker 生命周期仍为进程级常驻。
2. `sessions` 作为唯一跨阶段关联所有者，按 frame identity 组合 decode、upload 和 present duration，并输出 `framePipelineTiming`。Reader 和 App 不持有计时状态机。
3. 每次 output 激活只逐条保留前 12 个不同 frame 的首次 presentation；之后只保留端到端不低于 250 ms、present 不低于 100 ms、任一阶段不低于 100 ms、deadline miss 或错误。
4. `framePipelineTiming` 不进入 Debug Trace 时间桶合并；其他高频 frame/state 事件继续合并并保持有界。
5. Android texture 返回 queue、总 platform upload、retain、blit、schedule、replace、result dispatch；Dart 记录 MethodChannel round trip 与剩余 channel dispatch。总 `platformUpload` 只用于核对，dominant stage 使用互斥的 retain/blit/schedule/replace 和扣除这些子阶段后的 `platformOther`，禁止重叠计时重复归因。Flutter fallback 单独记录 fallback decode 和 presentation path。
6. `taskFailed` 保留 lane、role、lane queue、execution 与 task elapsed；失败路径不需要等到成功 presentation 才能诊断。source 已存在但 header 尚不足以分类时也必须累计 `sourceWait`。
7. promoted local artifact 的流式读取统一为 1 MiB；普通网络 transport 的 256 KiB 合同不变。
8. refresh in-flight future 必须先发布再启动实际刷新，避免同步完成 `loadStarted` 的调用方在 `_refreshInFlight` 赋值前发起第二次相同命令。

## 后果

- 新 trace 可以直接判断前帧卡在 worker startup、source、native decode、lane、Android copy/replace、未归因平台工作、主线程回调还是 Flutter fallback；失败任务也有同一 lane 时序。
- 如果所有记录阶段都很低而可见画面仍停顿，则剩余范围明确落在 MethodChannel 返回之后的 Flutter raster/compositor/display confirmation；当前 Android API 没有逐帧显示确认回调，不能伪造该数据。
- 本地 artifact stream 的 Dart 唤醒次数约降为原来的四分之一，不改变 DownloadSession、artifact 或 Pipeline 所有权。
