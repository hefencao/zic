# zic Implementation Status

**源码版本：** `0.31.0-dev.116`  
**App build：** `0.31.0+116`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3、composition 全局 5 槽、页面 rank 与 local/remote source bucket。
- 动画 staged c/n/m/p 为 8/6/4/3；last 暂停并保留 output。
- 纵向 Reader 按真实视口交叠建立 transition；current 前后 4 页统一保留轻量 host，不依赖 WebP hint。
-静态页在 96 MiB 推测预算内预热单帧 output，128 MiB FrameBudget 实际裁决。
- DecodeSession 在权威 cursor end 后上报静态/动画分类；Pipeline 运行时分类覆盖来源 hint并重新规划 demand。
-同章节至少两页确认静态且无动画证据时，未分类页可获得一帧预热；发现动画页即停止推断。
- durable cache 直连权威 DownloadSession ingress；空缓存自愈仍保留。
- cache backend 的 `invalidateArtifact` 是必需存储原语，tier/失效策略仍由中央 manager 负责。
- Android texture lease pool、事件驱动 waitingSource、partial WebP 自适应前缀保持。
- Android native build identity 仍为 dev.112，本轮未修改 Rust/JNI ABI。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.116 专项 gate | Verified-static |
| dev.75–dev.116 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| 运行时 WebP 分类、邻页预热与纵向顶部重载 | Unverified-device |

完整结果见 `docs/audits/dev116-validation-results.md`。
