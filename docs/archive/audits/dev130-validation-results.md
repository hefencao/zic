# dev.130 验证结果

## 修复

- 删除 Android output projector 对已删除 `_RetainedAndroidTextureOutputFrame` 的残余类型判断。
- Android projector 继续只接受 `_AndroidTextureOutputFrame`。
- dev.129 门禁现禁止该类型名称在生产代码中的任何残留；新增 dev.130 编译闭包门禁。

## 不变项

- fresh Reader texture 生命周期；
- performance-core affinity；
- one-shot playback deadline wake；
- 下载、decode、upload 水位与 partial source-growth；
- Android native build identity `zic-media-core-dev129-abi6-lib00121200`。

## 已执行并通过

- repository、documentation、Dart structure、directive order 与 Pipeline compile boundary；
- dev.75–dev.130 历史 ownership gates；
- quarantine、Trace analyzer 与 vertical geometry；
- Android texture Kotlin stub 编译；
- Android runtime/Trace、Mihon、Venera、Reader、Pipeline、UI、source binding、登录与设置合同；
- native header；
- 锁定 `libwebp-1.6.0.zip` 的全新 shared host build，以及 incremental/loop smoke。

## 未验证

当前环境没有 Dart/Flutter SDK、Android SDK/NDK、Cargo/rustc 和 ADB，因此没有执行 `flutter analyze`、Dart/Flutter owner tests、Android APK 构建、Rust Android target 编译或设备验证。
