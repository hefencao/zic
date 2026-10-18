# zic

`zic` 是面向 Android 优先、高性能漫画阅读场景的 Flutter/Rust 工程。项目支持本地与远程章节、静态图片、Animated WebP、持久下载、带分类/翻页的漫画源浏览、Mihon/Venera 扩展和统一 Reader Pipeline。

本文件只提供项目入口、构建命令和文档导航。版本历史、实验结论和单轮验证结果不写入 README。

## 文档导航

按以下顺序阅读：

1. [`docs/PROJECT_CHARTER.md`](docs/PROJECT_CHARTER.md)：目标、非目标和长期原则。
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：当前稳定所有权、依赖方向、数据流和生命周期。
3. [`docs/SPEC.md`](docs/SPEC.md)：产品与工程合同；描述“必须满足什么”，不声明当前已经通过。
4. [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)：当前源码状态、验证级别和未验证项。
5. [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md)：仍需执行的工作，不保存完成历史。
6. [`docs/NEXT_CHAT_HANDOFF.md`](docs/NEXT_CHAT_HANDOFF.md)：下一轮唯一基线和继续入口。
7. [`docs/DOCUMENTATION_POLICY.md`](docs/DOCUMENTATION_POLICY.md)：各文档职责和证据规则。
8. [`docs/IMPLEMENTATION_STATE.json`](docs/IMPLEMENTATION_STATE.json)：唯一当前需求状态、有效验收及剩余工作。

历史变更位于 [`CHANGELOG.md`](CHANGELOG.md)；既有技术决策与验证记录归档于 `docs/archive/adr/` 和 `docs/archive/audits/`，按需追溯并核对当前源码，暂不新增此类文件。

## 仓库结构

```text
apps/app/                  Flutter composition root、导航和产品页面
packages/domain/           领域 identity、值对象和不可变实体
packages/comic_translation/ 本地 OCR、文字翻译、模型管理与独立译文覆层
packages/catalog/          漫画源、manifest、稳定 catalog/cache identity
packages/resource_cache/   封面、详情、搜索和元数据响应缓存
packages/transport/        可取消、可分块 encoded-byte transport 合同
packages/storage/          partial、seal、promotion、索引和临时 workspace
packages/downloads/        页面 artifact cache、来源 transport、章节/整本下载
packages/sessions/         Download/Decode/Upload session、Reader-local decode source binding、lane、holder、timer
packages/pipeline/         Reader observation、角色窗口和纯 demand policy
packages/pipeline_runtime/ Reader 资源会话组合、retention 和只读页面流
packages/pipeline_native/  native source/cursor/uploader/output 原子能力组合
packages/media/            encoded source、cursor、frame、output 抽象
packages/reader/           通用 Reader observation、导航和 Flutter widget
packages/reader_runtime/   Reader Presentation、交互和 observation 适配
packages/local_media*/     本地文件/文件夹导入与展示
packages/plugin_host*/     插件信任、隔离、请求计划和 Android runtime 适配
packages/network_bridge/   浏览器、Cookie、challenge 和网络平台能力
packages/texture_bridge/   Android Flutter texture 与 SurfaceProducer 呈现
packages/bridge/           Dart FFI、native source/cursor/frame ABI 与 worker pool
packages/*_bridge/         storage、downloads、runtime 等平台组合适配
native/media_core/         Rust 增量媒体内核
third_party/source_archives/ 锁定第三方源码归档
tool/                      构建、验证、分析和仓库门禁
```

## 环境

最低要求由各 `pubspec.yaml`、`Cargo.toml` 和 Android 构建文件定义。常用工具：

- Flutter SDK / Dart SDK
- Android SDK、NDK、Gradle
- Rust / Cargo
- CMake、Ninja、Python 3
- Kotlin compiler（静态 bridge compile gate）

缺少工具链时，`tool/check.sh` 会执行可用的结构和静态门禁并明确输出跳过项；静态门禁不能替代 Flutter、Android 或真机验证。

## 初始化与运行

Flutter host 位于 `apps/app/`，不要在仓库根目录执行 `flutter create .`。

```bash
./tool/bootstrap_platforms.sh
./tool/run_android.sh
```

等价的直接运行方式：

```bash
cd apps/app
flutter pub get
python3 ../../tool/prepare_rhttp_android.py
python3 ../../tool/prepare_translation_android.py
flutter run --no-pub -d android
```

## 检查与测试

执行当前环境可用的全部检查：

```bash
./tool/check.sh
```

要求完整工具链，任何缺失都视为失败：

```bash
./tool/check.sh --require-toolchains
```

分项执行：

```bash
make analyze
make dart-test
make flutter-test
make rust-test
make webp-check
```

仓库规则禁止自动运行 `dart format`；修改应保持最小且手工格式化。

## Android 构建

```bash
./tool/build_android.sh debug
./tool/build_android.sh release
```

release 默认使用 `--split-per-abi`；构建成功后移除该模式遗留的通用 APK，并打印各架构包路径与体积。debug/profile/release 从同一个 `apps/app/android/zic-version.properties` 读取 application version。
首次构建会准备固定版本的 OCR 专用 OpenCV，保留 SIMD、TBB 和原有 HAL 加速；后续校验并复用，不打包模型权重。
原生库在 APK 内压缩，由系统安装时解压，运行时加载原始库文件；这会缩小 APK，但增加安装后的总占用。

## Native WebP

项目保留并校验 `third_party/source_archives/libwebp-1.6.0.zip`。源码准备和补丁应用必须通过锁定哈希与零 fuzz 检查：

```bash
./tool/prepare_webp.sh
./tool/check_webp.sh
```

展开源码、构建目录和安装产物写入 `.deps/`，不得进入交付 ZIP。普通构建不应依赖联网下载已有的锁定归档。

## Trace

Debug Trace 是诊断证据，不是产品状态数据库。分析逐帧 Pipeline 时使用：

```bash
python3 tool/analyze_frame_pipeline_trace.py zic-debug-trace-*.jsonl
```

Trace 的简短结论覆盖更新到现有状态；只有源码核对和对应验证支持的稳定合同才可进入 Architecture 或 Spec。`.log/` 只保留原始报障输入、开放问题的必要复现文件及当前复验结果；私有缓存执行同一规则。重复与过期产物及时删除，临时目录在成功或失败退出时清理。
