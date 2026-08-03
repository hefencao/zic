# zic

`zic` 是面向 Android 优先、高性能漫画阅读场景的 Flutter/Rust 工程。项目支持本地与远程章节、静态图片、Animated WebP、持久下载、漫画源扩展和统一 Reader Pipeline。

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

历史变更位于 [`CHANGELOG.md`](CHANGELOG.md)；技术决策位于 `docs/adr/`；单轮问题清单、Trace 分析和验证记录位于 `docs/audits/`。

## 仓库结构

```text
apps/app/                 Flutter 应用与 composition root
packages/domain/          领域 identity、值对象和不可变实体
packages/catalog/         漫画、章节、来源抽象和元数据
packages/resource_cache/  封面、详情和搜索响应缓存
packages/downloads/       持久下载、整章/整本调度和下载状态
packages/sessions/        Download/Decode/Upload session 生命周期
packages/pipeline/        Reader observation、角色窗口和 demand policy
packages/pipeline_runtime/ Pipeline-owned Reader 资源运行时
packages/pipeline_native/  native media capability 的上层组合
packages/reader_runtime/   Reader Presentation 与 observation 适配
packages/plugin_host/      插件信任、权限、请求计划和生命周期
packages/plugin_host_bridge/
                           Android 隔离进程与插件平台适配
packages/network_bridge/   Android 浏览器、Cookie 和网络平台能力
packages/texture_bridge/   Android Flutter texture 呈现
packages/bridge/           Dart FFI 与 native source/cursor/frame ABI
native/media_core/         Rust 增量媒体内核
third_party/source_archives/
                           锁定的第三方源码归档
tool/                      构建、验证、分析和仓库门禁
```

## 环境

最低要求由各 `pubspec.yaml`、`Cargo.toml` 和 Android 构建文件定义。常用工具：

- Flutter SDK / Dart SDK
- Android SDK、NDK、Gradle
- Rust / Cargo
- CMake、Ninja、Python 3
- Kotlin compiler（仅静态 bridge compile gate 需要）

缺少工具链时，`tool/check.sh` 会执行可用的结构和静态门禁，并明确输出跳过项；不能把静态门禁当作 Flutter、Android 或真机验证。

## 初始化与运行

Flutter host 位于 `apps/app/`，不要在仓库根目录执行 `flutter create .`。

```bash
./tool/bootstrap_platforms.sh
./tool/run_android.sh
```

等价的直接运行方式：

```bash
cd apps/app
flutter run -d android
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

release 默认使用 `--split-per-abi`，避免生成包含全部 ABI 的单一 fat APK。

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

Trace 中的性能结论应记录到 `docs/audits/`，只有经过源码核对和相应验证后，稳定合同才可进入 Architecture 或 Spec。
