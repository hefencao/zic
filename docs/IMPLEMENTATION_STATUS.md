# zic Implementation Status

**源码版本：** `0.31.0-dev.109`  
**App build：** `0.31.0+109`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`；单轮 Trace 与命令见 `docs/audits/`。

- **Implemented**：源码与引用闭包已核对。
- **Verified-static**：静态、脚本、stub 或 host 检查通过。
- **Verified-toolchain**：对应 Flutter/Rust/Android 工具链检查通过。
- **Verified-device**：修复后已在设备复验。
- **Unverified**：实现存在但对应验证未完成。
- **Quarantined**：测试目标仍有效但现有形态不稳定。

## 当前所有权

| 领域 | 权威所有者 |
|---|---|
| 普通网络响应缓存 | `resource_cache` |
| Reader page-artifact tier 路由、L1 bytes、join 与 write-through | `downloads.ArtifactCacheManager` |
| partial、seal、promotion 与 backend storage | `storage` + `ArtifactCacheBackend` |
| Reader demand/session | `pipeline` + `pipeline_runtime` + `sessions` |
| Reader Presentation | `reader_runtime` |
| native decode与 Android window/blit | `bridge` + `native/media_core` |
| SurfaceProducer 与 schedule | `texture_bridge` |
| composition/navigation | `apps/app` |

## 当前实现快照

- 窗口保持下载 7/3、预解码 2/1、上传 current/transition、lane 5/3/2。
- 两个 Dart decode isolate 常驻；libwebp 1.6.0 锁定、帧内单线程、current 两个 successor。
- `ArtifactCacheManager` 内聚 memory tier、LRU、in-flight join、memory→backend lookup、长度校验、write-through 和 invalidation。
- `ArtifactCacheBackend` 只提供 immutable promoted artifact 的 open/store；普通 response cache 保持独立。
- Android geometry 与一次 lock retry 内聚在既有 Rust `NativeBlitter.blit` JNI；Kotlin 不再声明独立 configure。
- Android native 产物使用 source build ID、JNI symbol 检查与 Gradle preBuild gate，拒绝旧 `.so`。
- quarantine 使用稳定 `Q-xxx` ID；稳定文档遵守 `DOCUMENTATION_POLICY.md`。

以上为 Implemented；工具链与设备验证状态见本轮 audit。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.109 ownership gates | Verified-static |
| pinned libwebp host prepare/build/smoke | Verified-static（host-native） |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK debug/release | Unverified：当前环境无 Android toolchain |
| dev.109 platform presentation/device re-entry | Unverified-device |

完整结果见 `docs/audits/dev109-validation-results.md`。
