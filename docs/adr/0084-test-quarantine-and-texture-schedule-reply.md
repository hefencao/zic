# ADR 0084：测试隔离所有权与 Android texture schedule/reply 顺序

- 状态：接受；quarantine marker 的版本绑定机制由 ADR 0085 修正
- 版本：`0.31.0-dev.100`
- 基线：`0.31.0-dev.99`

## 背景

错误报告 51 同时包含测试编译漏项、与当前产品合同相反的断言、跨多个页面 bootstrap 的异步超时，以及真实的前帧播放停顿。把这些失败统一当成产品回归会诱导为测试修改产品；把它们全部删除又会丢失 locator refresh 与 retry 的回归意图。

新的设备 Trace 还显示，dev.99 把大量 successor 的提前解码等待记成 `decodedToUpload` 主导项；真正的首帧平台路径中，RGBA copy 很快，但 `SurfaceProducer.scheduleFrame` 所在的 Android platform-thread 队列和随后第二次 result post 会显著推迟 Dart playback timer。

## 决策

1. 默认测试中任何 `skip` 都必须使用已登记的稳定 `ZIC-QUARANTINE(Q-xxx):` ID，在 `docs/testing/TEST_QUARANTINE.md` 登记失效原因、仍运行的所有者级覆盖与解除条件，并由 `tool/check_test_quarantine.py` 限定允许集合。
2. 删除重复或概念错误的断言，而不是保留永久 skip：
   - App 不再重复测试 `reader_runtime` 的 adaptive classifier；
   - 删除无法代表最终 renderer 放大的 `RasterPlan.isRenderUpscaled`；
   - 删除把 Flutter filter quality 当成 codec resize 证据的断言。
3. 三个依赖 Whole-App catalog/route bootstrap 顺序的 Source Browser 测试临时隔离；legacy locator 的 gateway/plugin-host 所有者测试继续运行。
4. Android texture present 保持严格顺序：native blit 完成后，在 platform thread 真正执行 `SurfaceProducer.scheduleFrame()`；blit lane 等待该执行完成，再直接提交 thread-safe `MethodChannel.Result`。禁止在 schedule 尚未执行时提前回复，也禁止再排第二个 main-thread result runnable。
5. App 在 `runApp` 前同时预热两个 Dart decode worker 与一个 1×1 Android texture lease，lease 立即释放，不转移 texture 生命周期所有权。
6. `decodedToUpload` 拆为：
   - `decodedLeadMicros`：successor 在前一帧 deadline 前已完成的正常提前量；
   - `uploadBackpressureMicros`：超过可上传 deadline 后仍等待的真实阻塞。
   `decodedLead` 不参与 dominant stage。

## 所有权

- 测试隔离登记和门禁：repository tooling。
- classifier 算法测试：`reader_runtime`。
- raster decode target：`pipeline`；最终 filter：Presentation renderer。
- Android surface schedule、blit 和 reply 顺序：`texture_bridge`。
- decode/upload/present 时间关联：`sessions`。
- Trace 离线归一化：`tool/analyze_frame_pipeline_trace.py`。

## 被否决方案

- 为通过 Whole-App 超时测试改变来源加载、导航或持久化产品逻辑。
- 使用无原因的 `skip: true` 或仅写 flaky。
- 在 App 再复制 reader classifier 单元测试。
- `scheduleFrame` 尚未在 platform thread 执行就从 blit lane 返回成功；这会让 playback 推进先于纹理可见。
- 继续将完整 `decodedToUpload` 作为性能瓶颈；它包含有意的 successor lead。
