# zic Implementation Status

**源码版本：** `0.31.0-dev.115`  
**App build：** `0.31.0+115`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3、composition 全局 5 槽、页面 rank 与 local/remote source bucket。
- 动画 staged c/n/m/p 为 8/6/4/3；last 暂停并保留 output。
- 纵向 Reader 按真实视口交叠建立 transition；静态页在 96 MiB 推测预算内预热单帧 output，128 MiB FrameBudget 实际裁决。
- 纵向静态 current 前后 4 页保留轻量 host；Widget 不持有 decoded frame、texture、cache bytes 或 session。
- durable cache 直连权威 DownloadSession ingress；cache-resident promoted session 不再回写空临时 artifact。
-中央 cache 与 backend 禁止并自愈 0 字节/长度漂移条目，自动回源；空响应不能进入 promoted 状态。
- Android texture lease pool、事件驱动 waitingSource、partial WebP 自适应前缀保持。
- Android native build identity 仍为 dev.112，本轮未修改 Rust/JNI ABI。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.115 专项 gate | Verified-static |
| dev.75–dev.115 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| 空缓存自愈与纵向顶部重载设备效果 | Unverified-device |

完整结果见 `docs/audits/dev115-validation-results.md`。
