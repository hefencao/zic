# dev.125 Validation Results

## 已执行

- repository、documentation、Dart structure、directive order：通过。
- Pipeline runtime compile boundary：通过。
- dev.124/dev.125 静态合同：通过。
- Android texture Kotlin stub：通过，包含 redraw MethodChannel。
- Trace analyzer fixture：通过，包含 retained restore 与 source-growth wait。
- 锁定 `libwebp-1.6.0.zip` shared host build、incremental/loop smoke：通过。

## 设备输入基线

- 首帧中位数约 269 ms；后台恢复后的两次首帧约 1.19–1.20 秒。
- dev.124 Trace 中 retained output restore 为 0；没有观测到 partial decode failure，因此该项来自源码边界审计。

## 未验证

当前环境没有 Flutter/Dart、Android SDK/NDK/Gradle、Cargo/rustc 或 ADB。新增 Dart owner tests、Android APK、后台恢复真机效果和 partial failure 真机路径均未执行。
