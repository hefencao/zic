# dev.103 Validation Results

## 版本

- 源码：`0.31.0-dev.103`
- App build：`0.31.0+103`
- 中文提交标题：`修复 Reader 重进平台队列与逐帧确认延迟`

## 已执行

### Repository 与静态合同

通过：

- repository / documentation / Dart structure / directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.103 ownership gates；
- test quarantine；
- texture timing contract；
- frame pipeline analyzer fixture；
- Android runtime/Trace；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network/native/headers/preflight/bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- native header。

### Android texture Kotlin

`tool/test_texture_bridge_kotlin_compile.py` 使用包含 `BinaryMessenger.TaskQueue`、四参数 `MethodChannel` 和 `Handler.postAtFrontOfQueue` 的 stub 编译通过。

### libwebp

在外部干净依赖目录中通过：

- 项目内锁定 `libwebp-1.6.0.zip`；
- 零 fuzz VP8 TLS patch prepare；
- host shared CMake/Ninja build；
- incremental 与 loop Animated WebP smoke。

### Trace analyzer

- dev.102 输入 Trace 可读取；
- 无进程级 session lifecycle 的旧 Trace 被标记为 `per-session-legacy-clock`，不再计算伪造的全局 source 并发；
- decoded/upload role 不同的等待归入 lead；
- dev.103 lifecycle/process-clock fixture gate 通过。

## 组合检查说明

`tool/check.sh` 的一次组合运行在 Kotlin 编译前后达到单次命令执行窗口。已从未执行项分组继续，所有分组均通过；该超时没有记作通过或失败。

## 未执行

当前环境缺少：

- Flutter/Dart SDK；
- Android SDK/NDK 与 Gradle；
- Cargo/rustc；
- ADB/设备。

因此未执行或未声称通过：

- `flutter analyze`；
- Dart/Flutter tests；
- Android debug/release；
- Rust tests；
- dev.103 真机首次进入与重进播放复验。
