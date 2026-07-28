# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader、可恢复下载、
持久化缓存恢复、容量/LRU 策略、受控清理、失败退避重试、独立资源 lane、格式感知 ingress、
decode/upload registry、frame holder、viewport 播放门控、帧字节预算、可运行的 Animated WebP App 入口、viewport/DPR 自适应显示目标、source-aware 解码 raster，以及 Rust 增量 Animated WebP 解码基础。

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

## App 演示入口

App 不再启动后直接进入静态章节。首页提供五个明确入口：

```text
100 页静态章节
Reader 媒体管线
内置动图 WebP
导入本地 WebP
导入图片文件夹
```

内置动图来自 `native/media_core/testdata/` 的真实 decoder fixtures，并同步到：

```text
apps/app/assets/demo/animated/
  animated.webp
  finite_loop.webp
  partial_blend.webp
  index.json
```

运行：

```bash
cd apps/app
flutter run -d android
```

所有 WebP 入口默认使用确定性的 `Flutter codec`，打开文件不会自动进入
FFI/texture。Reader 与文件夹切换页固定使用安全 codec；独立预览中的
`Native（实验）` 必须由用户显式选择并在确认对话框中再次确认；
初始化、上传或生命周期操作失败时回退 Flutter codec。Native 路径会验证 ABI
和锁定的 libwebp 1.6.0 运行时，并使用 source/cursor/frame ABI 解码真实 RGBA 帧。

“导入本地 WebP”读取单个 `.webp`。“导入图片文件夹”通过系统目录选择器取得
目录路径，在后台 isolate 中递归枚举所有普通文件，只读取文件头识别 PNG、JPEG、
GIF、WebP、BMP、TIFF、ICO、AVIF 和 HEIF，不信任扩展名或大小写。识别结果按
自然路径顺序生成显式相对显示名，并在只保留一个当前播放器的页面中提供上一项、
下一项和文件菜单切换；完全没有可识别图片时才报告空目录诊断。

Reader 媒体入口已使用真实 `LiveCoordinator` 和 `DownloadRegistry`。页面需求从
manifest identity 生成 `DownloadId`，经 AssetBundle/file/http transport 下载到
promoted artifact 后，播放器才读取最终字节。viewport target 更换或页面退出会
先 reconcile 掉旧需求，避免后台下载和旧 decode identity 残留。当前可见 WebP
仍固定使用 Flutter codec；native texture 只在独立预览中显式确认后启用。

Native 与 Flutter codec 使用同一个自适应物理显示目标：目标取实际预览区域的逻辑尺寸乘以设备 DPR，保持源图比例并按 8 个物理像素对齐。`RasterPlan` 再决定实际 decode raster：大图按目标下采样，小图保持原始画布，避免 animated codec 在合成局部子帧前先放大插值。极小素材显示时使用 nearest-neighbour，正常漫画页面继续使用平滑滤镜。Native 路径还会提前准备下一帧，并从帧时长中扣除准备耗时，避免解码时间把动画总时长拉长。

同步 native fixture 到 App assets：

```bash
./tool/sync_demo_webp_assets.sh
```

仓库检查会逐字节比较 App asset 与 native fixture，避免 UI 演示与 decoder
测试样本发生漂移。

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

## Native WebP 源码构建

项目不接受外部预编译的 Android libwebp 目录。host 与 Android native 构建都使用
`native/libwebp.lock` 固定的官方源码版本、仓库和 commit：

```text
libwebp 1.6.0
commit 4fa21912338357f89e4fd51cf2368325b59e9bd9
```

首次执行会把源码拉取到 `.deps/src/`，构建和安装结果写入 `.deps/build/` 与
`.deps/install/`。这些目录不进入版本控制。

Host smoke 与 Rust 测试：

```bash
./tool/check_webp.sh
./tool/test_rust.sh
```

Android 三 ABI 构建：

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk
./tool/build_android_native.sh release
./tool/build_android.sh release
```

构建脚本通过 Android NDK CMake toolchain 从源码分别生成 `arm64-v8a`、
`armeabi-v7a` 和 `x86_64` 的 libwebp，再链接 `media_core`。默认从源码生成 PIC 静态归档并合入 `libmedia_core.so`，避免 Android APK 中的
版本化 SONAME 和传递依赖问题。`jniLibs` 默认只需要 `libmedia_core.so`。设置
`ZIC_ANDROID_WEBP_LINK=shared` 可用于显式的共享库调试构建。

网络受限时可指定一个受信任的源码 checkout：

```bash
export ZIC_WEBP_SOURCE=/path/to/libwebp
```

该 checkout 默认必须位于锁定 commit；只有明确的本地实验才使用
`ZIC_WEBP_ALLOW_UNPINNED=1`。构建会把上游 `COPYING`、`PATENTS` 和源码版本信息
写入 Android assets。native ABI v5 还会在运行时报告 decoder/demux 版本，
`NativeVersion.usesPinnedWebp` 可验证两者是否均为锁定的 1.6.0。
