# dev.111 Validation Results

## 版本

- 源码：`0.31.0-dev.111`
- App build：`0.31.0+111`
- 中文提交标题：`修复启动 Artifact 争用与解码失败停播`

## Verified-static

工作树分组执行通过：

- repository、documentation、Dart structure、directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.111 ownership gates；
- test quarantine、texture timing、vertical geometry/trace；
- Android texture Kotlin stub 编译；
- frame pipeline analyzer fixture；
- Android runtime dependency 与 Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network、native、headers、Reader preflight、bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- native header。

长检查按原顺序分组执行；达到单次命令窗口时只从未执行项继续，未把超时记作通过。

## libwebp source build

在全新外部依赖目录中通过：

- 项目内锁定 `libwebp-1.6.0.zip`；
- 哈希校验与零 fuzz VP8 TLS patch prepare；
- shared host CMake/Ninja build；
- incremental、partial-blend 与 finite-loop Animated WebP smoke。

## 稳定文档

`README.md`、`docs/ARCHITECTURE.md`、`docs/SPEC.md` 与 dev.110 基线 SHA-256 相同。

## Unverified

当前环境缺少 Flutter/Dart SDK、Android SDK/NDK/Gradle、Cargo/rustc 和 ADB，因此未执行或未声称通过：

- `flutter analyze` 与 Dart/Flutter tests；
- Android native/APK debug/release；
- Rust tests；
- dev.111 startup near-only pressure 与 buffered decode recovery 真机复验。

## ZIP 独立复验

候选 ZIP 从独立目录解压后通过：

- 禁入生成物扫描；
- repository、documentation、Dart structure、directive order；
- Pipeline runtime compile boundary；
- dev.104、dev.106、dev.110、dev.111 contracts；
- quarantine、Trace analyzer、Kotlin texture compilation；
- 使用包内锁定归档和全新外部依赖目录重新执行 shared host libwebp build 与三种 Animated WebP smoke。

正式 ZIP 在补写本记录后再次独立解压执行关键门禁和增量 libwebp smoke。
