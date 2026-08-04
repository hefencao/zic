# zic Implementation Status

**源码版本：** `0.31.0-dev.114`  
**App build：** `0.31.0+114`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载 demand 保持前 7 / 后 3；composition 共享全局 5 槽 `NetLane`，页面使用唯一 rank，并按 local/remote source bucket 限流。
- 动画页 staged decode c/n/m/p 上限保持 8/6/4/3；last 暂停并保留 output。
- 纵向 Reader 按页面与视口真实交叠投影 transition；相邻页一进入视口即建立 demand，不再等待中心交接。
- 静态页每页只解码一帧；Pipeline 在 96 MiB 推测预算内选择邻近静态 decode/upload，128 MiB FrameBudget 负责实际 output 回收。静态纵向轻量 host cache extent 为 4 屏。
- partial WebP 按 `DownloadId + frameIndex` 学习最小 decode prefix；sealed failure 不参与 chunk 学习。
- durable cache response 直连权威 DownloadSession ingress；Android texture lease pool 位于 composition；`waitingSource` 由 source revision 事件唤醒。
- Android native build identity 仍为 dev.112，因为本轮没有修改 Rust/JNI ABI。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.114 专项 gate | Verified-static |
| dev.75–dev.114 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| 纵向真实可见 demand / 静态预算真机效果 | Unverified-device |

完整结果见 `docs/audits/dev114-validation-results.md`。
