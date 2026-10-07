# ADR 0093：Artifact tier 内聚与 Android native build identity

**状态：Provisional**

> 2026-09-13 clarification：ADR 0313 后续恢复了一个 **acceleration-only** `NativeBlitter.prepare` JNI，仅供 exact-size idle texture prewarm 在真实 frame 到达前预配置 RGBA geometry。它不恢复本 ADR 否决的独立 correctness `configure` authority：`blit` 仍必须独立检查 geometry 并在需要时配置/重试；废弃的 `NativeBlitter.configure` 仍被 build/symbol gate 拒绝。

## 背景

dev.108 设备 Trace 证明统一 `ArtifactCacheManager` 已命中 memory tier，Reader dispose 也已收敛到百毫秒内；但全部逐帧样本仍走 Flutter fallback。错误为 Android 运行库不存在 Kotlin 新声明的 `NativeBlitter.configure` JNI 方法。源码、Kotlin 与实际 APK 中的 `.so` 形成了不完整的公共 API 迁移。

同时，dev.108 的 manager 仍通过独立 `PromotedArtifactByteCache` 和 `ArtifactCacheStore`/`ArtifactCacheStreamStore` 过渡接口组合 L1。该拆分没有独立生命周期或策略价值，增加了旁路 API 与重复测试。

## 决策

1. `downloads.ArtifactCacheManager` 内聚 L1 LRU、in-flight join、memory→backend lookup、长度验证、write-through 与 invalidation。
2. `ArtifactCacheBackend` 只保留 `openArtifactStream` 和 `storePromotedArtifact` 两个存储原语。删除 `ArtifactCacheStore`、`ArtifactCacheStreamStore`、独立 `PromotedArtifactByteCache` 与 backend `readArtifact` 旁路。
3. `contains` 表示任意 tier 可读；`containsBackend` 只表示 backend 已持久化。handoff 必须使用后者，L1 命中不得伪装成 durable write-through。
4. 删除独立 `NativeBlitter.configure` JNI。Kotlin 只调用既有 retain/release/blit；Rust `blit` 读取 window geometry，仅在尺寸/格式不匹配或一次 lock failure 后配置并重试。
5. Android native 构建输出必须带源树 build ID。`check_android_native.sh` 验证 build ID 与 retain/release/blit JNI 符号，并拒绝废弃 configure 符号。
6. Gradle `preBuild` 必须拒绝缺失或陈旧 native marker/ABI library，不能静默打包旧 `.so`。
7. Surface 重配置通过现有 blit 返回码投影为 `surfaceReconfigureCount`；旧 configure/retry 字段只作为 Trace analyzer 的历史兼容输入。

## 所有权

- `downloads.ArtifactCacheManager`：Reader page-artifact tier 策略。
- `ArtifactCacheBackend`：可替换存储原语。
- `native/media_core`：ANativeWindow geometry、lock、blit 与一次重试。
- `texture_bridge`：SurfaceProducer、现有 JNI 调用、schedule 和只读 telemetry。
- build tooling / Gradle：native 产物身份与符号闭包。

## 被否决方案

- 继续增加独立 cache facade 或 backend-specific presence：重复策略所有权。
- 将 page artifact 并入普通 response cache：partial/promotion 与 TTL response 语义不兼容。
- 保留独立 configure JNI 并仅修改打包脚本：扩大公开 ABI，且配置本就属于 blit 的 native window 生命周期。
- 每帧调用 `setBuffersGeometry`：恢复已否决的性能退化。
- Kotlin 在 JNI 调用失败后永久使用 Flutter fallback：会掩盖 native 构建闭包错误。

## 解除 Provisional 条件

Android debug/release 使用重新构建的 `.so`，设备 Trace 显示 platform presentation 恢复、缺失 JNI 错误消失、`surfaceReconfigureCount` 只在首次/resize/recreate 或一次 lock retry 出现，并完成快速重进验证。
