# dev.113 Validation Results

## 版本

- 源码：`0.31.0-dev.113`
- App build：`0.31.0+113`
- Android native build identity：保持 dev.112；本轮未修改 Rust/JNI ABI。
- 中文提交标题：`复用 Android Texture 并直连持久 Artifact Source`

## 已执行

### Repository 与静态合同

分组通过：

- repository / documentation / Dart structure / directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.113 ownership gates；
- quarantine、texture timing、vertical geometry/Trace；
- Android runtime dependency 与 Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network、native、headers、Reader preflight、bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- native header；
- Python compile 与 shell syntax。

历史 dev.77 与 dev.96 门禁原先硬编码直接释放 texture lease 和临时 presenter 预热；已改为验证 pooled lease 归还与 factory-shared presenter，未放宽原所有权目标。

耗时组合命令多次达到单次执行窗口，均从未执行项继续；超时本身没有记作通过或失败。

### Android texture Kotlin

`tool/test_texture_bridge_kotlin_compile.py` 使用 stub 编译通过。

### libwebp

在全新外部依赖目录 `/mnt/data/zic_dev113_deps` 中通过：

- 项目内锁定 `libwebp-1.6.0.zip`；
- 零 fuzz VP8 TLS patch prepare；
- host shared CMake/Ninja build；
- incremental、partial-blend 与 finite-loop Animated WebP smoke。

### Trace analyzer

fixture 通过并增加：

- cache-resident ingress 数量、native ingress 与 artifact-write timing；
- texture lease presentation 与 reuse 数量；
- 原有 ranked download、source read、refill、recovery、last keep 和 Reader lifecycle。

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
- dev.113 真机 direct ingress、texture reuse 与首帧效果。
