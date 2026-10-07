# dev.112 Validation Results

## 版本

- 源码：`0.31.0-dev.112`
- App build：`0.31.0+112`
- 中文提交标题：`统一页面下载排序并自适应 WebP 解码前缀`

## 已执行

### Repository 与静态合同

分组通过：

- repository / documentation / Dart structure / directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.112 ownership gates；
- quarantine、texture timing、vertical geometry/Trace；
- Android runtime dependency 与 Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network、native、headers、Reader preflight、bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- native header；
- Python compile 与 shell syntax。

组合命令多次达到单次执行窗口；均从未执行项继续。超时本身没有记作通过或失败。

### Android texture Kotlin

`tool/test_texture_bridge_kotlin_compile.py` 使用 stub 编译通过。

### libwebp

在全新外部依赖目录 `/mnt/data/zic_dev112_deps` 中通过：

- 项目内锁定 `libwebp-1.6.0.zip`；
- 零 fuzz VP8 TLS patch prepare；
- host shared CMake/Ninja build；
- incremental、partial-blend 与 finite-loop Animated WebP smoke。

### Trace analyzer

fixture 通过并覆盖：

- ranked download 的 global/bucket active；
- partial decode-prefix threshold；
- partial/sealed failure classification；
- staged refill、decode recovery、last keep；
- source read、cache handoff 与 Reader lifecycle。

## 未执行

当前环境缺少：

- Flutter/Dart SDK；
- Android SDK/NDK、Gradle 与 ADB；
- Cargo/rustc。

因此未执行或未声称通过：

- `flutter analyze`；
- Dart/Flutter owner tests；
- Android native/APK debug/release；
- Rust tests；
- dev.112 真机全局并发、页面 rank 与 adaptive prefix 效果。
