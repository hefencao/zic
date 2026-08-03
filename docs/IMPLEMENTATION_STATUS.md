# zic Implementation Status

**源码版本：** `0.31.0-dev.107`  
**App build：** `0.31.0+107`

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
| 网络响应缓存 | `resource_cache` |
| partial、promotion、持久下载和 promoted encoded-byte cache | `storage` + `downloads` |
| Reader demand policy | `pipeline` |
| Reader 资源会话 | `pipeline_runtime` + `sessions` |
| Reader Presentation | `reader_runtime` |
| native decode ABI / worker pool | `bridge` + `native/media_core` |
| Android texture | `texture_bridge` |
| 插件与平台桥 | `plugin_host` + bridge packages |
| composition / navigation | `apps/app` |

## 当前实现快照

- Pipeline 窗口保持下载 7/3、预解码 2/1、上传 current/transition、lane 5/3/2。
- 两个 Dart decode isolate 常驻；libwebp 1.6.0 使用锁定离线归档、零 fuzz 补丁和帧内单线程。
- persistent artifact background 使用 1 MiB chunk quantum；foreground 压力期 background 同时最多一个 chunk 槽。
- current/transition 使用 composition encoded-byte LRU、foreground lease-through-stream 和 startup pressure；encoded bytes 以 1 MiB progressive startup segments 进入权威 DownloadSession。
- promoted handoff 在 materialize 临时 artifact 前探测相同 identity 与长度的持久副本；命中时跳过重复回写。
- Reader dispose 分阶段记录 coordinator、handoff、media、downloads 与 workspace；DecodeSession retained cursor、Android texture 与 playback timing 合同不变。
- quarantine 使用稳定 `Q-xxx` ID；稳定文档按 `DOCUMENTATION_POLICY.md` 分责。

上述为 Implemented。Flutter、Android 构建与设备结果不能由静态状态推导。

## 当前测试隔离

`Q-001`、`Q-002`、`Q-003` 仍登记于 `docs/testing/TEST_QUARANTINE.md`。

## 本轮验证矩阵

| 检查 | 状态 |
|---|---|
| repository / documentation / Dart structure / directive order | Verified-static |
| dev.75–dev.107 所有权门禁 | Verified-static |
| Trace analyzer fixture | Verified-static |
| pinned libwebp prepare/build/smoke | Verified-static（host-native） |
| `flutter analyze` 与 Dart/Flutter tests | Unverified：当前环境无 Flutter SDK |
| Rust tests | Unverified：当前环境无 Cargo/rustc |
| Android debug/release | Unverified：当前环境无 Android toolchain |
| dev.107 重进清理与 progressive ingress | Unverified-device |

完整结果写入 `docs/audits/dev107-validation-results.md`。
