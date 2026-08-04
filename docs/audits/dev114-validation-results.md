# dev.114 Validation Results

## 版本

- 源码：`0.31.0-dev.114`
- App build：`0.31.0+114`
- Android native build identity：保持 dev.112；本轮未修改 Rust/JNI ABI。
- 中文提交标题：`修复纵向可见页 Demand 并按内存保留静态输出`

## 已执行

### Repository 与静态合同

分组通过：

- repository、documentation、Dart structure、directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.114 ownership gates；
- quarantine、texture timing、vertical geometry/Trace；
- Android runtime dependency 与 Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network、native、headers、Reader preflight、bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- native header、Python compile 与 shell syntax。

### Android texture Kotlin

`tool/test_texture_bridge_kotlin_compile.py` 使用 stub 编译通过。

### libwebp

在全新外部依赖目录 `/mnt/data/zic_dev114_deps` 中通过：

- 项目内锁定 `libwebp-1.6.0.zip`；
- 零 fuzz VP8 TLS patch prepare；
- host shared CMake/Ninja build；
- incremental、partial-blend 与 finite-loop Animated WebP smoke。

### Trace analyzer

fixture 通过并增加：

- static warm decode/upload 最大值；
- page host dispose 和无首帧 dispose 统计；
- FrameBudget output 回收统计。

修复前纵向静态 Trace 作为基线：8 个 host dispose，其中 4 个未得到首帧。旧 Trace 没有 dev.114 `staticWarm*` 字段，因此不能用它证明新策略已生效。

## 未执行

当前环境缺少 Flutter/Dart SDK、Android SDK/NDK/Gradle/ADB 和 Cargo/rustc，因此未执行或未声称通过：

- `flutter analyze`；
- Dart/Flutter owner tests；
- Android native/APK debug/release；
- Rust tests；
- dev.114 纵向真实可见 demand、静态内存预算与 host 保留的真机效果。
