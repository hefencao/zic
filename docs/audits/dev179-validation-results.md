# dev.179 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.178_vibevenera-rhttp-startup-transport.zip`。
- 当前版本：Source `0.31.0-dev.179`，Android `versionCode=179`。
- 设备证据：`zic-debug-trace-2026-08-09T02-48-10.jsonl`。
- 当前执行环境有 Python、Git、Kotlin/JVM；没有 Flutter/Dart/pub、Cargo/Rust或完整 Android SDK/NDK，因此不宣称 `flutter pub get`、`flutter analyze`、Flutter/Dart tests、Rust tests或 APK build 已执行通过。
- dev.178基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；未从旧版本补入。

## Trace 根因量化

结构化扫描共 3110 条事件；其中 25 条 origin `sourceRead`：

- `openMicros`：最小 228,511；中位 6,203,446；p90 约 8,114,298；最大 8,430,833。
- `streamMicros`：中位约 6,508,454；p90约 13,141,069；最大 20,941,756。
- `firstChunkMicros` 中位仅约 5,198，说明 response建立后的第一个Rust packet并不是秒级瓶颈。
- rhttp/raw reqwest packet高度碎片化：15,640,724 bytes 被上抛为 10,713 chunks，单包约 1,204–1,460 bytes；20,133,362 bytes 被上抛为 13,790 chunks，单包约 1,422–1,460 bytes。多个大图都出现约 6k–14k 个 packet。

这证明 dev.178 虽切到与 VibeVenera 同类的 Rust/rhttp engine，但漏掉了参考实现的 stream framing；每个底层小 packet都会放大成 Dart Stream调度、DownloadJob commit、artifact/native/status处理。dev.179因此只在 transport boundary聚合：首个逻辑块64KiB，后续256KiB，最终 remainder flush；不改变 NetLane、DownloadSession、artifact、7/3/2/1窗口或5/3/2 lane ownership。

## 依赖 / Android 构建链

本轮按“最新且处于共同稳定兼容矩阵”升级，而不是机械追最大版本号：

- Workspace最低环境：Dart >=3.12、Flutter >=3.44。
- rhttp 0.18.0；flutter_lints 6、file_selector 1.1、ffi 2.2、crypto 3.0.7、sqlite3 3.5、path_provider 2.1.6、test 1.31.2。
- Android：compileSdk 37；Kotlin 2.4.10；AGP 9.1.1；Gradle 9.3.1；JDK17 daemon criteria。
- 五个本地Flutter Android插件删除自行apply KGP与legacy `kotlinOptions`，改为Built-in Kotlin迁移兼容形式 `kotlin.compilerOptions`；稳定Flutter 3.44阶段仍保留Flutter兼容开关，待Flutter 3.47+ stable后再正式启用Built-in Kotlin。
- OkHttp 5.4.0、jsoup 1.22.2、Gson 2.14.0、kotlinx-coroutines 1.11.0、kotlinx-serialization 1.11.0、org.json 20260522。
- Mihon source/runtime ABI SHA、Injekt、QuickJS、RxJava1以及生成兼容runtime asset使用的旧编译器/stdlib不是普通应用依赖，继续证据化固定；本轮不把“升级依赖”扩展成extension ABI变更。

`gradle/gradle-daemon-jvm.properties`固定Daemon JVM 17；Gradle Client仍由启动wrapper的 `JAVA_HOME/PATH`决定，因此开发机若使用高版本Java启动wrapper，仍应把 `JAVA_HOME`对齐JDK17，而不是用native-access参数掩盖。

## 已执行验证

- `check_dart_structure.py`：345 Dart files / 130 test files。
- Dart library directive order、documentation responsibility/current consistency。
- 104个 `test_dev*.py` 中103个明确PASS；dev.98仅因当前基线缺 pinned libwebp archive排除。
- Android runtime dependency closure/mutation gates。
- Mihon Payload Context实际Kotlin编译、ABI routing、split classloader、chapter contract。
- Venera bootstrap/network/native-binary/Reader preflight/response-header contracts。
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture、texture bridge Kotlin compile、native header。
- `python3 -m py_compile tool/*.py` 与全部 shell syntax。

`python3 tool/check_repo.py` 当前只停止于继承的 pinned libwebp archive缺失，没有新的repository boundary错误。

## pub lock限制

当前环境没有 Dart/Flutter/pub，因此没有手工修改或伪造 `pubspec.lock`。dev.178 lock尚未包含rhttp；应用Patch或完整包后必须先由真实pub工具执行：

`flutter pub get`

再执行 `flutter analyze` / `flutter test` / Android build。本轮源码固定的是依赖约束与构建配置，不把未由pub生成的archive hash写进lock。

## Patch 预回放

写入本validation前，从全新dev.178项目根目录生成预Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

结果：1161个发行文件、53个实际修改/新增文件；missing=0、extra=0、content diff=0、executable-bit diff=0。预回放曾发现dev.175历史gate的工作目录mode污染，已按dev.178基线恢复为0755，正式Patch不包含该无关mode变化。

加入本validation后的候选回放包含1162个发行文件、54个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新dev.178重新生成最终Patch并再次执行 `git apply --check --index` / `git apply --index` 与完整manifest/mode比较。最终发行只有在冻结后的结果仍为1162 / 0 / 0 / 0 / 0时成立。
