# dev.107 Validation Results

**状态：当前环境验证完成；Flutter/Android/设备验证未完成**

## 已执行并通过

- `bash -n tool/*.sh`
- `python3 -m py_compile tool/*.py`
- repository structure、documentation responsibility、Dart structure、directive order
- Pipeline runtime compile boundary
- dev.75–dev.107 ownership/regression gates
- test quarantine、texture schedule timing、Trace analyzer fixture
- Android texture Kotlin stub compilation
- Android runtime/dependency/Trace contracts
- Mihon entry、Context、ABI、classloader、read-only payload、chapter contracts
- Venera network、native binary、headers、Reader preflight、bootstrap contracts
- source binding、Reader settings、Pipeline demand/streaming、UI architecture、external login/settings
- native header check
- 项目内锁定 `libwebp-1.6.0.zip` 的 archive/hash、零 fuzz prepare
- 全新外部依赖目录的 host shared CMake/Ninja build
- incremental、partial-blend 与 finite-loop Animated WebP smoke

完整 `tool/check.sh` 在 Kotlin 阶段达到单次执行窗口限制；未执行部分随后按原顺序分组执行通过。超时本身没有记录为通过。

## 结构审查

- `ArtifactCachePresenceStore` 只位于 `downloads`，memory/persistent store 均实现。
- handoff 的 presence probe 位于 `BytesBuilder` 前。
- current/transition delivery 为 `startup-segmented`，foreground lease 仍保持到 stream drain/discard。
- Reader dispose 在 coordinator 关闭前 detach handoff listener，并记录五个阶段耗时。
- README、Architecture、Spec 与 dev.106 基线 SHA-256 完全一致。

## 当前环境不可执行

| 检查 | 原因 |
|---|---|
| Dart/Flutter owner tests、`flutter analyze` | 无 Dart/Flutter SDK |
| Android debug/release 与真机 Trace | 无完整 Android SDK/NDK/Gradle/ADB |
| Rust tests | 无 Cargo/rustc |

## 设备待验证

- `session-artifact-handoff` 对 cache-hit 页面产生 `skip-existing`；
- `handoffDrainMicros` 不再形成秒级长尾；
- current/transition 为 `deliveryMode=startup-segmented`；
- 首个 1 MiB 后 source-ready/decode 可推进；
- 快速退出重进时旧 Reader 不再覆盖新 Reader 的主要播放区间；
- current decode failure 与新页偶发不播放是否仍存在。
