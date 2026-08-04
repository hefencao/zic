# zic Implementation Status

**源码版本：** `0.31.0-dev.112`  
**App build：** `0.31.0+112`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 下载 demand 保持前 7 / 后 3；页面传输使用 composition 共享的全局 5 槽 `NetLane`。
- 每页按 current/transition/方向/距离获得唯一 download rank；退出窗口时取消该 Reader 对应的 active/queued task。
- local/content/asset 共用本地来源 bucket；远程按 `sourceId` 分 bucket。当前各 bucket 上限为 5，可由未来来源能力降低。
- artifact scheduler 继续提供 foreground/background chunk 公平性，但不再使用 startup priority floor；startup pressure 在 output 已呈现且 `c>4` 后释放。
- decode 使用 staged c/n/m/p 上限 8/6/4/3；last 暂停并保留 output，不继续下载解码。
- partial WebP 按 `DownloadId + frameIndex` 学习最小 decode prefix：local 1 MiB、remote 256 KiB 阶梯；sealed source 不参与 chunk 学习。
- current/transition generic decode failure 保留 buffered successor，并使用最多四次 revision-bound recovery。
- Artifact cache、Android texture、native build identity 与 libwebp 所有权保持。

以上为 Implemented。设备效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.112 ownership gates | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| global rank / adaptive prefix 真机效果 | Unverified-device |

完整结果见 `docs/audits/dev112-validation-results.md`。
