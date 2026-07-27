# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader、可恢复下载、
持久化缓存恢复、容量/LRU 策略、受控清理、失败退避重试、独立资源 lane、格式感知 ingress、
decode/upload registry、frame holder、viewport 播放门控、帧字节预算，以及 Rust 增量 Animated WebP 解码基础。

```text
ReaderView
  -> ReaderObs
  -> ReaderBinding
       -> ViewportResolver / playback gate
  -> HeuristicPolicy
  -> DemandPlan
  -> LiveCoordinator
       -> NetLane
       -> DecodeLane
       -> UploadLane
       -> DownloadRegistry / DownloadJob / DownloadSession
            -> Ingress / SourcePool
       -> DecodeRegistry / DecodeSession / FrameHolder
       -> UploadRegistry / UploadSession / OutputFrame
       -> FrameBudgeter (current reserve)

CacheIndex
  -> CachePolicy (LRU candidate selection)
  -> CacheOps (session-safe trim / clear)

media
  -> content sniff -> WebP-only source allocation
  -> artifact rebuild -> encoded source

Rust media_core
  -> source create / append / seal / reset
  -> epoch + contiguous offset + memory budget
  -> libwebp partial demux
  -> complete-frame decode + blend/dispose composition
  -> retained immutable RGBA frame handles
  -> frame/play-count metadata + explicit cursor rewind
```

## 生成 Flutter 平台工程

平台工程属于 Flutter App，而不是 monorepo 根目录。解压后进入仓库根目录 `zic/`，
可以直接运行：

```bash
./tool/bootstrap_platforms.sh
```

等价的手动命令是：

```bash
cd apps/app
flutter create \
  --empty \
  --project-name zic \
  --org dev.zic \
  --platforms=android,ios \
  .
```

不要在仓库根目录执行 `flutter create .`，否则 Android/iOS host 会生成到错误层级。

## 测试目录

从仓库根目录运行全部 Flutter 测试：

```bash
./tool/test_flutter.sh
# 或
make flutter-test
```

脚本实际执行：

```bash
cd packages/reader && flutter test test
cd apps/app && flutter test test
```

纯 Dart package 测试：

```bash
./tool/test_dart.sh
# 或
make dart-test
```

运行 App：

```bash
cd apps/app
flutter run -d android
```

完整检查：

```bash
./tool/check.sh --require-toolchains
```

完整架构、规格、计划与实施状态位于 `docs/`。

## 构建 Android split APK

从仓库根目录运行：

```bash
./tool/build_android.sh release
# 或
make android-apk
```

脚本固定使用 `--split-per-abi`，分别生成各 ABI 的 APK，避免发布单个包含全部
native ABI 的 fat APK。调试构建可执行：

```bash
./tool/build_android.sh debug
```

## Native WebP 开发依赖

桌面 Rust 构建需要 `libwebp`、`libwebpdemux` 和 `pkg-config`。先运行：

```bash
./tool/check_webp.sh
cargo test --workspace
```

Android 原生库按 ABI 构建时，准备以下目录：

```text
$ZIC_ANDROID_WEBP_ROOT/
  arm64-v8a/lib/libwebp.so + libwebpdemux.so
  armeabi-v7a/lib/libwebp.so + libwebpdemux.so
  x86_64/lib/libwebp.so + libwebpdemux.so
```

然后运行：

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
export ZIC_ANDROID_WEBP_ROOT=/path/to/android-webp
./tool/build_android_native.sh release
./tool/build_android.sh release
```

默认使用共享 libwebp；设置 `ZIC_ANDROID_WEBP_LINK=static` 可使用 PIC 静态归档。
当前版本已完成真实 cursor/frame 解码、显式 cursor step、有限/无限循环和
Android 多 ABI 原生库打包；Kotlin `SurfaceProducer` 与纹理上传仍在下一阶段。
