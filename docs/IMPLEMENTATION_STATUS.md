# zic Implementation Status

**源码版本：** `0.31.0-dev.113`  
**App build：** `0.31.0+113`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载 demand 保持前 7 / 后 3；composition 共享全局 5 槽 `NetLane`，页面使用唯一 rank，并按 local/remote source bucket 限流。
- staged decode c/n/m/p 上限保持 8/6/4/3；last 暂停并保留 output，不继续下载或解码。
- partial WebP 按 `DownloadId + frameIndex` 学习最小 decode prefix；sealed failure 不参与 chunk 学习。
- `ArtifactCacheManager` 统一 memory/persistent tier。durable cache response 直连权威 DownloadSession ingress，不再写 Reader 临时 artifact；origin/partial/resume writer 不变。
- Android texture lease pool 位于 media runtime factory composition；current 可依据页面元数据预热真实尺寸 output，session close 后 lease 可复用。
- `waitingSource` decode 由 source revision 事件唤醒；没有新字节时不重复提交普通 refill。
- Android native build identity 仍为 dev.112，因为本轮没有修改 Rust/JNI ABI。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.113 专项 gate | Verified-static |
| dev.75–dev.113 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| direct ingress / texture reuse 真机效果 | Unverified-device |

完整结果见 `docs/audits/dev113-validation-results.md`。
