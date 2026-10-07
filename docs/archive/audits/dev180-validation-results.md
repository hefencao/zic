# dev.180 验证结果

## 基线与环境

- 唯一代码基线：`zic_v0.31.0-dev.179_modern-toolchain-rhttp-stream-framing.zip`。
- 当前版本：Source `0.31.0-dev.180`，Android `versionCode=180`。
- 设备输入：`zic-debug-trace-2026-08-09T04-18-30.jsonl`。
- 当前执行环境有 Python、Git、Node、Kotlin/JVM 编译工具；没有 Flutter/Dart SDK、完整 Android SDK/NDK、Rust，因此不宣称 `flutter pub get`、Flutter/Dart tests、APK build或Rust tests已通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py`仅在该既有缺件处停止，未从旧包补入。

## Trace 根因验证

trace共6208条事件，包含271次`downloadPriorityChanged`、205次`pageTransition`、137次`demandDetached`。窗口policy持续生成11个download demand，7/3本身没有整体失效。

current 104→105的一次稳定切换中：旧current对应active download发生priority 1000→0、reason=`retained-background`；同一时刻另一active download从0→780。结合dev.179源码，previous current被互斥赋为`PageRole.last`，forward/backward loop又跳过last，于是104不再占offset -1 previous，较远页错误递补为previous。

修复后`RoleWindow.roles`只描述相对资源位置，上一current的presentation retention独立为`retainedIndex`。相邻旧current仍产生previous/next download/decode；大跳后远离7/3窗口的旧current仅保upload/output，不产生冗余网络/解码。

## 工具链验证

- 全workspace直接`test`约束已从`^1.31.2`收回`^1.25.0`；当前lock中的test 1.31.0 / test_api 0.7.11落在该约束可接受范围，但最终依赖解析仍以用户本地Flutter3.44执行`flutter pub get`为准。
- App与五个本地Android plugin使用AGP9.3.1；wrapper使用Gradle9.5.0；compileSdk=37。
- `gradle-daemon-jvm.properties`使用`toolchainVersion=25`，匹配用户OpenJDK25构建环境。
- App与本地plugin的Java `sourceCompatibility/targetCompatibility`及Kotlin `JvmTarget`继续17；构建JDK与Android class-file target保持分离。

## 实际执行通过

- Dart structure：345 files / 130 test files；directive order通过。
- dev.75–97、dev.99–180全部历史Python ownership gates通过；dev.98仅因继承的pinned libwebp archive缺失排除。
- dev.110旧last-frame gate已迁移：继续验证last upload/frame retention与holder水位，同时拒绝“last吞掉previous slot”的旧实现。
- `test_pipeline_demand_stability.py`迁移为同时比较relative roles与`retainedIndex`，避免retention变化被unchanged-plan shortcut吞掉。
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture通过。
- Venera bootstrap/network/native-binary/response-headers/Reader-preflight通过。
- Mihon entry/payload Context Kotlin compile、ABI routing、split classloader、read-only payload、chapter contract通过。
- Android runtime dependency closure/mutation与texture bridge Kotlin compile通过。
- documentation/current-code documentation、Python compile、shell syntax、native-header检查通过。

## Repository check

`python3 tool/check_repo.py`只停止于继承的`third_party/source_archives/libwebp-1.6.0.zip`缺失，没有新的repository错误。

## Patch 预回放

写入本validation文件前，从全新dev.179项目根目录生成预Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

预回放为1165个发行文件、42个修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本validation文件后的候选回放为1166个发行文件、43个修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新dev.179重新生成正式Patch，并重复`git apply --check --index`/`git apply --index`与完整manifest/mode比较。最终发行只有在结果仍为1166 / 0 / 0 / 0 / 0时成立。
