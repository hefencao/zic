# dev.137 验证结果

## 修复前设备证据

- 首页第一封面请求：约 1,881,489 µs；服务 ready 约 54 ms。
- 封面 source cache ready：通常 4–14 ms；source ready 后首帧通常 27–77 ms。
- 远程 source read：p95 约 8.70 s，最大约 10.86 s。
- 典型 17.9–20.2 MiB 页面含约 12,236–13,850 个 transport chunk，平均约 1.4 KiB。

## 已执行

- repository、documentation、Dart structure、directive order、Pipeline compile boundary。
- dev.75–dev.137 历史所有权门禁。
- dev.137 progressive primary、chunk coalescing、flow-gate 和 stable-profile 专项门禁。
- Trace analyzer fixture 与原设备 Trace 分析。
- Android/Mihon/Venera/Reader/Pipeline/UI 静态合同。
- Kotlin texture bridge stub。
- 锁定 libwebp 1.6.0 shared host build、incremental/loop smoke。
- clean dev.136 patch check/apply、逐文件比较和正式 ZIP 独立复验。

## 未验证

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK、Cargo/rustc 和 ADB，因此未执行 Flutter analyzer/tests、Android APK 构建或目标设备验证。
