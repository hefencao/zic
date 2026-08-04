# zic Implementation Status

**源码版本：** `0.31.0-dev.110`  
**App build：** `0.31.0+110`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

## 验证等级

- **Implemented**：源码与引用闭包已建立。
- **Verified-static**：当前环境的静态、stub 或 host 检查通过。
- **Verified-toolchain**：对应 Flutter/Rust/Android 工具链通过。
- **Verified-device**：修复后已经设备复验。
- **Unverified**：实现存在但对应验证未完成。
- **Quarantined**：测试目标有效，但当前测试形态不稳定。

## 当前实现

- 下载窗口保持前 7 / 后 3，lane 保持 5/3/2。
- decode 使用 staged c/n/m/p 水位上限：c 8、n 6、m 4、p 3；每次只补一个阶段，transition 作为逻辑 n。
- last 是上一次 current：暂停播放并保留既有 output，不继续下载或解码；重新成为 current/transition 时恢复。
- current/transition/last output 受 frame budget 保护；last decoded successors 可回收。
- DecodeSession 每产出一帧即可唤醒 upload，refill 与首帧呈现并行。
- Pipeline page output 同一 identity 只允许一个 in-flight presentation，首 Surface 不再被后续 frame generation 作废。
- Artifact cache、native texture、libwebp 与 Android native build identity 维持 dev.109 所有权边界。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.110 ownership gates | Verified-static |
| pinned libwebp host build/smoke | Verified-static |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android native/APK | Unverified：当前环境无 toolchain |
| staged waterline / last keep / first Surface | Unverified-device |

完整结果见 `docs/audits/dev110-validation-results.md`。
