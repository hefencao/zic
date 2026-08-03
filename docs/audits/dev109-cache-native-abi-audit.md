# dev.109 Cache 内聚与 Android native ABI 审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.108_unified-artifact-cache-texture-geometry.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-03T15-28-26(1).jsonl`。

## 问题清单

### 编译 / 打包

- Kotlin 新声明 `NativeBlitter.configure`，但设备 `.so` 没有相应 JNI 符号。每帧调用均抛出 `No implementation found`，随后永久回退 Flutter。
- Android 构建没有源树 build identity，也没有 JNI symbol gate；旧 `.so` 可静默留在 `jniLibs` 并进入 APK。

### 产品 / 性能

- Trace 的 163 个逐帧样本全部为 `flutterFallback`；249 次 fallback 来自缺失 configure JNI。
- 第二次 Reader 已命中 memory tier，handoff 均为 `skip-existing`，dispose 约 49/72 ms；缓存不是本轮持续卡顿的主要根因。
- fallback 仍承担每帧 RGBA 跨语言传递与 Flutter decode，端到端 p95 约 1.92 s。

### 架构 / 冗余

- `ArtifactCacheManager` 外仍有独立 `PromotedArtifactByteCache`，但其生命周期、LRU、join 和失效均由 manager 驱动，没有独立所有权。
- `ArtifactCacheStore`、`ArtifactCacheStreamStore` 与 backend `readArtifact` 是迁移期旁路；生产只需 manager 和 backend 的 open/store 原语。
- dev.105/dev.108 版本门禁绑定了已删除过渡类型，阻碍真正内聚。

## 所有权清单

| 状态/资源 | 正确所有者 | 本轮修改 |
|---|---|---|
| L1 bytes、LRU、join、tier lookup | `ArtifactCacheManager` | 内聚到 manager 私有状态 |
| durable/in-memory storage primitive | `ArtifactCacheBackend` | 只保留 open/store |
| handoff durable presence | manager `containsBackend` | 不允许 backend-specific presence |
| Surface geometry 与 lock retry | Rust `NativeBlitter.blit` | 删除独立 JNI configure |
| JNI/APK build identity | build tooling + Gradle | marker、symbol gate、preBuild failure |
| texture schedule/presentation | `texture_bridge` | 不获得 geometry 策略 |

## 被否决方案清单

- 仅提高缓存容量或继续增加 presence facade：Trace 已证明 memory 命中但仍全量 fallback。
- 保留独立 configure JNI：配置属于 native blit 生命周期，且会扩大 ABI 漂移面。
- 设备缺方法时静默 fallback：必须在构建阶段失败。
- 把所有缓存并入普通 response cache：语义和 writer 生命周期不一致。
- 保留只被旧门禁引用的 cache 文件与测试：已删除并迁移必要覆盖。

## 删除内容

- `packages/downloads/lib/src/promoted_artifact_byte_cache.dart`
- `packages/downloads/test/promoted_artifact_byte_cache_test.dart`
- `tool/test_dev105_direct_artifact_hot_cache.py`
- `tool/test_dev108_cache_manager_texture_geometry.py`
- `ArtifactCacheStore`、`ArtifactCacheStreamStore` 和 backend `readArtifact` API
- 独立 `NativeBlitter.configure` JNI 与 Kotlin configuration state

## 未验证

当前环境没有 Flutter/Android SDK、NDK、Cargo/rustc 和设备，因而 native Android `.so`、APK 和 platform presentation 尚未实际构建/复验。
