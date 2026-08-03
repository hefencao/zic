# zic Implementation Status

**源码版本：** `0.31.0-dev.101`  
**App build：** `0.31.0+101`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`；本轮 Trace、命令与数值见 `docs/audits/`。

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
| partial、promotion、持久下载 | `storage` + `downloads` |
| Reader demand policy | `pipeline` |
| Reader 资源会话 | `pipeline_runtime` + `sessions` |
| Reader Presentation | `reader_runtime` |
| native decode ABI / worker pool | `bridge` + `native/media_core` |
| Android texture | `texture_bridge` |
| 插件信任与请求计划 | `plugin_host` |
| Android 插件隔离 | `plugin_host_bridge` |
| 浏览器和 Cookie 平台能力 | `network_bridge` |
| composition / navigation | `apps/app` |

未发现需要由 App 或 Reader 重新拥有的缓存、session、transport 或 texture 状态。

## 当前实现快照

- Pipeline 窗口保持下载 7/3、页面预解码 2/1、上传 current/transition、lane 5/3/2。
- 50% current/transition 交接和 same-key follow 已实现。
- 两个 Dart decode isolate 进程期常驻，current 保留高优先级槽。
- libwebp 1.6.0 使用锁定离线归档、零 fuzz 补丁和帧内单线程。
- current 保留两个 successor；本地/promoted artifact 使用 1 MiB，普通网络使用 256 KiB。
- 前帧 timing 已覆盖 source、两级队列、native decode、upload 和 Android texture；dev.101 新增 schedule queue/call 拆分字段。
- README、Architecture、Spec、Plan、Status 和 Handoff 已按 `DOCUMENTATION_POLICY.md` 分责，仓库门禁防止逐轮内容回流。

上述均为 Implemented；具体静态和 host-native 验证见本轮 validation audit。Flutter、Android 构建和设备结果不能由这些状态推导。

## 当前测试隔离

- `Q-001`：legacy runtime route refresh；
- `Q-002`：persisted legacy Venera refresh；
- `Q-003`：transient source retry。

原因、保留覆盖和解除条件见 `docs/testing/TEST_QUARANTINE.md`。未登记 `skip` 会被仓库门禁拒绝。

## 本轮验证矩阵

| 检查 | 状态 |
|---|---|
| repository / Dart structure / directive order | Verified-static |
| documentation responsibility gate | Verified-static |
| dev.75–dev.99 历史所有权门禁 | Verified-static |
| quarantine 与 texture timing contract | Verified-static |
| Kotlin texture stub compile | Verified-static |
| Trace analyzer fixture | Verified-static |
| Android/Mihon/Venera/Reader/Pipeline/UI 合同 | Verified-static |
| pinned libwebp prepare/build/smoke | Verified-static（host-native） |
| `flutter analyze` | Unverified：当前环境无 Flutter SDK |
| Dart/Flutter tests | Unverified：当前环境无 Flutter SDK |
| Rust tests | Unverified：当前环境无 Cargo/rustc |
| Android debug/release | Unverified：当前环境无 Android toolchain |
| dev.101 真机播放 | Unverified |

完整命令和超时续跑说明见 `docs/audits/dev101-validation-results.md`。

## 开放问题

1. Animated WebP 前几帧仍有长尾延迟，dev.101 timing 字段尚未采集设备 Trace。
2. 1 MiB persistent artifact stream 仍可能受并发读取、session copy 或 Dart 调度影响。
3. 当前 Trace 含一次 current decode failure，尚未完成错误链闭环。
4. 三项 Source Browser 测试仍处于 quarantine。
5. Flutter analyzer/tests、Android build 和真机复验尚未执行。
