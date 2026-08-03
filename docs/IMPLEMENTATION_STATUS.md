# zic Implementation Status

**源码版本：** `0.31.0-dev.108`  
**App build：** `0.31.0+108`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`；单轮 Trace、命令与数值见 `docs/audits/`。

## 状态等级

- **Implemented**：源码和引用闭包已核对。
- **Verified-static**：当前环境的静态、Python、shell、Kotlin stub 或 host-native 检查通过。
- **Verified-toolchain**：对应 Flutter/Rust/Android 工具链检查通过。
- **Verified-device**：修复后已在设备复验。
- **Unverified**：实现存在，但对应工具链或设备验证未完成。
- **Quarantined**：测试目标仍有效，但现有测试形态不能稳定证明目标。

## 当前所有权

| 领域 | 权威所有者 |
|---|---|
| identity / 值对象 | `domain` |
| 漫画、章节、来源元数据 | `catalog` |
| 普通网络响应缓存 | `resource_cache` |
| Reader page-artifact tier 路由与 hot bytes | `downloads.ArtifactCacheManager` |
| partial、seal、promotion 与持久存储 | `storage` + chapter `ArtifactCacheBackend` |
| Reader demand policy | `pipeline` |
| Reader 资源会话 | `pipeline_runtime` + `sessions` |
| Reader Presentation | `reader_runtime` |
| native decode ABI / worker pool | `bridge` + `native/media_core` |
| Android texture | `texture_bridge` + `native/media_core` |
| 插件与平台桥 | `plugin_host` + bridge packages |
| composition / navigation | `apps/app` |

## 当前实现快照

- Pipeline 窗口保持下载 7/3、预解码 2/1、上传 current/transition、lane 5/3/2。
- 两个 Dart decode isolate 常驻；libwebp 1.6.0 使用锁定离线归档、零 fuzz 补丁和帧内单线程。
- composition 级 `ArtifactCacheManager` 统一 Reader artifact 的 memory→backend lookup、读取可见性/backend 持久存在性、长度校验、并发完整读取合并、LRU和写穿。
- Memory/Persistent chapter service 是可替换 `ArtifactCacheBackend`，不再各自实现 presence/tier 策略；persistent read 直接由 durable index/path 解析 ready artifact。
- transport、handoff、presentation bytes loader 与快速重进共享同一个 manager；普通 response cache 仍独立。
- Android texture 在首次、resize、Surface 重建或一次 lock failure 后配置 buffer geometry；禁止每帧配置。
- Reader dispose 通过 lane `cancelAll()` 清除 active 与 pending task；生命周期 Trace 保留分阶段耗时。
- quarantine 使用稳定 `Q-xxx` ID；稳定文档按 `DOCUMENTATION_POLICY.md` 分责。

上述为 Implemented。Flutter、Android 构建与设备结果不能由静态状态推导。

## 当前测试隔离

`Q-001`、`Q-002`、`Q-003` 仍登记于 `docs/testing/TEST_QUARANTINE.md`。

## 本轮验证矩阵

| 检查 | 状态 |
|---|---|
| repository / documentation / Dart structure / directive order | Verified-static |
| dev.75–dev.108 所有权门禁 | Verified-static |
| Trace analyzer 与 Kotlin texture stub | Verified-static |
| pinned libwebp prepare/build/smoke | Verified-static（host-native） |
| `flutter analyze` 与 Dart/Flutter tests | Unverified：当前环境无 Flutter SDK |
| Rust tests | Unverified：当前环境无 Cargo/rustc |
| Android debug/release | Unverified：当前环境无 Android toolchain |
| dev.108 cache routing / texture geometry / Reader 重进 | Unverified-device |

完整结果写入 `docs/audits/dev108-validation-results.md`。
