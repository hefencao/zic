# zic Implementation Status

**源码版本：** `0.31.0-dev.111`  
**App build：** `0.31.0+111`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 下载窗口保持前 7 / 后 3，lane 保持 5/3/2。
- decode 使用 staged c/n/m/p 水位上限：c 8、n 6、m 4、p 3；transition 是逻辑 n。
- last 暂停并保留既有 output，不继续下载或解码；重新成为 current/transition 时恢复。
- DecodeSession 每产出一帧即可唤醒 upload；Pipeline page output 串行发布首 Surface。
- startup artifact pressure 只允许 n/m/p 的 priority≥680 近邻读取；far 7/3 artifact 保持 demand 但延后到 current output 已呈现且 c=8 后实际读取。
- current/transition decode failure 保留已解码 holder；UploadSession 继续消费 buffered successor，并执行最多四次 revision-bound 有界恢复。
- Artifact cache、Android texture、native build identity 与 libwebp 维持 dev.109 所有权边界。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.111 ownership gates | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| startup pressure / buffered decode recovery | Unverified-device |

完整结果见 `docs/audits/dev111-validation-results.md`。
