# ADR 0313：Exact texture prewarm 的 native geometry prepare

**状态：Accepted**

## 背景

Reader 的 exact-size Android `SurfaceProducer` prewarm 已能在 source-canvas metadata 可用后提前创建并初始化 texture lease，设备 trace 也证明首个真实 upload 会复用该 lease；但 prewarm 的 `initialize()` 只 materialize `SurfaceProducer.surface`。真正的首帧 `NativeBlitter.blit` 仍第一次调用 `ANativeWindow_setBuffersGeometry`，因此 baseline 五次 cold Reader 的 frame0 全部记录 `surfaceReconfigureCount=1`。

ADR 0093 曾删除独立 `NativeBlitter.configure` JNI，因为当时 Kotlin 与 APK 内旧 `.so` 发生 ABI 漂移，而且 configure 被当成 presentation correctness 前置条件。当前 native build identity 与 symbol gate 已能机械拒绝缺失/陈旧 ABI，因此可以重新评估“提前准备 geometry”，但不能恢复第二个 correctness owner。

## 决策

1. `texture_bridge` 增加 `NativeBlitter.prepare(surface,width,height)`，仅由从未呈现过的 exact-size idle prewarm lease 在 serialized blit lane 的 `initialize()` 阶段调用。
2. `prepare` 复用 Rust `configure_if_needed`，只把当前 exact decoded raster 的 RGBA geometry 尽早写入 `ANativeWindow`；它不 lock/post frame、不调用 `scheduleFrame()`，也不改变 playback/freeze/resume、Pipeline demand、NetLane 或 cache authority。
3. `prepare` 是 acceleration-only。失败时该 speculative prewarm 失败并释放 lease；真实 upload 仍可重新 acquire，并由 `NativeBlitter.blit` 独立读取 geometry、必要时配置、lock-failure 后最多再配置一次。`blit` 仍是 presentation correctness authority。
4. 废弃的 `NativeBlitter.configure` 继续禁止。新增 prepare JNI 属于真实 ABI 变化，native identity 从 `dev135-abi6` 提升到 `dev136-abi7`，Android symbol gate 必须要求 prepare/retain/release/blit 四个 JNI 符号。
5. 不新增 UI/pipeline 层 geometry 状态，也不让 prewarm completion 成为 Reader route readiness 或 first-frame eligibility gate。

## 设备证据

同一缓存漫画、同一设备、force-stop cold Reader，baseline 与 candidate 各取五个有效样本：

- frame0 `surfaceReconfigureCount`：baseline 5/5 为 1；candidate 5/5 为 0。
- frame0 present 中位：19.36 ms → 15.35 ms。
- platform upload 中位：17.97 ms → 13.47 ms。
- frame0 end-to-end 中位：80.30 ms → 73.26 ms。
- mount→first-frame 中位：168.92 ms → 164.04 ms。
- 五个 candidate run 均无 `taskFailed`、FATAL 或 ANR。

source wait / native decode 仍有较大样本抖动，因此该优化只解释为移除了首帧 surface geometry 配置的可观测成本，不宣称整体首帧稳定下降同等幅度。

## 被否决方案

- 恢复旧 `NativeBlitter.configure` 并让 Kotlin 维护 `needsConfiguration`：重新产生第二个 correctness owner，且扩大状态同步面。
- 只依赖真实 `blit` 首帧配置：正确但稳定支付一次首帧平台配置成本，已有 exact-size prewarm 无法覆盖这段工作。
- 把 geometry prepare 上移到 Pipeline/Reader：presentation 资源细节外泄，违反 owner 边界。
- 通过更强 NetLane/local-read gate 给首帧让路：与本问题无关，并会重新引入已删除的跨 owner 耦合。
