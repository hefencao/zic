# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader、可恢复下载、
持久化缓存恢复、容量/LRU 策略、受控清理、失败退避重试、独立资源 lane、格式感知 ingress、
decode registry、frame holder，以及 Rust 增量媒体字节源基础。

```text
ReaderView
  -> ReaderObs
  -> HeuristicPolicy
  -> DemandPlan
  -> LiveCoordinator
       -> NetLane
       -> DecodeLane
       -> UploadLane
       -> DownloadRegistry / DownloadJob / DownloadSession
            -> Ingress / SourcePool
       -> DecodeRegistry / DecodeSession / FrameHolder

CacheIndex
  -> CachePolicy (LRU candidate selection)
  -> CacheOps (session-safe trim / clear)

media
  -> content sniff -> WebP-only source allocation
  -> artifact rebuild -> encoded source

Rust media_core
  -> source create / append / seal / reset
  -> epoch + contiguous offset + memory budget
  -> incremental WebP/GIF signature boundary
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
