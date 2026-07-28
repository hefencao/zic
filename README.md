# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader、可恢复下载、
持久化缓存恢复、容量/LRU 策略、受控清理、失败退避重试、独立资源 lane、格式感知 ingress、
decode/upload registry、frame holder、viewport 播放门控、帧字节预算、可运行的 Animated WebP App 入口、viewport/DPR 自适应显示目标、source-aware 解码 raster、Rust 增量 Animated WebP 解码基础，以及按 `sourceId + comicId` 聚合多章节的 Android Home/Bookshelf/详情闭环。`0.20.0-dev.23` 统一首页与书架封面、补齐分类与管理操作、自定义画廊拖动，并为 Reader 增加沉浸控制与缩放。`0.21.0-dev.24` 新增第三个漫画源页面、持久化源管理、底部源切换和首个可浏览的 MangaDex 远程源；远程章节继续进入现有目录库与 Reader artifact 管线。`0.21.1-dev.25` 修复生成 Android host 的发布联网权限，补充可选择/复制的完整漫画源错误诊断、连接超时和有界瞬时重试。`0.22.0-dev.26` 统一漫画源、首页更新、阅读历史和书架的详情页，并以来源感知的章节身份合并上游目录与已持久化章节，支持下拉更新。

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

## 漫画源

主导航第三页为漫画源浏览，首次进入时才创建远程浏览页。顶部入口管理源的启用状态与顺序，页面底部在已启用源之间切换。当前内置 `MangaDexSource`，支持分页发现、标题搜索、详情、章节列表以及加入书架或直接打开。源层只产生 catalog manifest；漫画源、首页更新、阅读历史和书架入口复用同一个详情投影。完整上游章节目录按 `sourceId + chapterId` 与已保存章节合并，新发现章节在用户打开或明确加入前不会写入 `ImportedLibraryStore`；已保存但上游暂时缺失的章节继续显示为本地保留。远程章节写入后仍由 `ReaderRuntimeScreen -> DownloadSession -> promoted artifact` 读取。

详情页支持下拉更新和顶部刷新按钮。刷新只调用漫画源、目录扫描器和目录库各自的契约，不把网络、目录或 Reader 资源所有权转移到 Widget。远程作者、简介和封面身份随已保存章节向后兼容地持久化，因此从首页或历史进入时不会退化成另一套简化详情。

远程图片交付 URI 可能变化，因此 `ImportedPageRecord` 单独保存源提供的稳定 page ID。每次打开远程章节会重新解析当前 manifest，再按稳定 page ID 迁移阅读位置。当前内置源只请求英文 safe/suggestive 内容，不包含账户登录、Cookie、反爬挑战或站点绕过。

所有 WebP 入口默认使用确定性的 `Flutter codec`，打开文件不会自动进入
FFI/texture。Reader 与文件夹切换页固定使用安全 codec；独立预览中的
`Native（实验）` 必须由用户显式选择并在确认对话框中再次确认；
初始化、上传或生命周期操作失败时回退 Flutter codec。Native 路径会验证 ABI
和锁定的 libwebp 1.6.0 运行时，并使用 source/cursor/frame ABI 解码真实 RGBA 帧。

“导入本地 WebP”读取单个 `.webp`。“导入图片文件夹”在 Android 使用持久化
SAF document-tree 授权，在桌面使用后台 isolate 递归枚举普通文件；两条路径都以
文件头优先识别 PNG、JPEG、GIF、WebP、BMP、TIFF、ICO、AVIF 和 HEIF，不信任
扩展名或大小写。导入结果转换为本地章节并通过 DownloadSession/promoted artifact
进入统一 Reader。章节记录和最后阅读页保存在本地 SQLite 目录库，应用重启后可从
首页重新打开；完全没有图片时才报告带扫描计数的空目录诊断。

Reader 媒体入口已使用真实 `LiveCoordinator` 和 `DownloadRegistry`。页面需求从
manifest identity 生成 `DownloadId`，经 AssetBundle/file/http transport 下载到
promoted artifact 后，播放器才读取最终字节。viewport target 更换或页面退出会
先 reconcile 掉旧需求，避免后台下载和旧 decode identity 残留。当前可见 WebP
仍固定使用 Flutter codec；native texture 只在独立预览中显式确认后启用。

Reader 默认以 `immersiveSticky` 进入并隐藏顶部、底部控制栏，轻触页面显示或再次隐藏。
底部滑杆直接提交有边界校验的 `ReaderController.requestPage`；旋转只改变页面呈现，
不会重写下载 identity。双指缩放和双击缩放由当前页 `InteractiveViewer` 持有，放大时
暂停 PageView 翻页，跳到其他页后重置旧页缩放。暂停和倍速继续复用原 `NativeWebpPlayer`
与 Flutter codec 路径，不旁路 download identity、telemetry 或 raster 下采样。当前“缓存本章”
会把本章页面推进到当前 Reader 会话的 promoted artifact；离开 Reader 后仍会清理临时根，
持久离线下载状态与书架水位投影留给后续存储阶段。

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

平台生成脚本会继续执行：

```bash
python3 tool/configure_platforms.py
```

该步骤会幂等地向 Android 主 manifest 加入 `android.permission.INTERNET`。对于已经存在的
Android host，更新源码后也应执行一次；发布 APK 不应依赖只在开发 host 中存在的权限。
推荐从仓库根目录使用统一运行入口：

```bash
./tool/run_android.sh
```

它会先生成或修复 host，再执行 `flutter run -d android`。直接运行 Flutter 命令前也可以
手动执行 `python3 tool/configure_platforms.py`。

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
