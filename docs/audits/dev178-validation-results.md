# dev.178 验证结果

## 环境与唯一基线

- 唯一代码基线：`zic_v0.31.0-dev.177_vibevenera-retained-preemption-download-manager-route-first.zip`。
- 输入设备证据：`zic-debug-trace-2026-08-09T01-44-16.jsonl`。
- 对照源码：文件库权威无后缀 `vibevenera-master.zip`，只读使用。
- 当前版本：Source `0.31.0-dev.178`，Android `versionCode=178`。
- 当前环境有 Python/Git/Kotlin/JVM/Node；没有 Dart/Flutter/pub、完整 Android SDK/NDK与可用Cargo工具链，因此不宣称 `flutter analyze`、Dart/Flutter tests、APK build、Rust tests或 `flutter pub get` 已执行。

## Trace结论

新trace的remote current首播不是被native decode主导。代表样本：

- page 193：mount→first-frame约8.69s；current拿到origin前约3.71s；首帧直到source prefix约286KiB时才可解码，第一帧native decode约62ms。
- page 141：mount→first-frame约3.66s；相邻/当前source open分别可见约2.31s/3.44s量级等待。
- cached pages约33–223ms即可首帧，说明Reader/widget/native首帧机制本身不是4–8s固定成本。

因此剩余首播差距主要位于source request-plan/HTTP open与首个可解码prefix吞吐。对照VibeVenera后确认其仍保留download 7/3、decode 2/1和5/3/2 lane，不以缩小预取窗口换首帧；其主图片HTTP使用Rust/rhttp流式transport。

## dev.178实现边界

- `NetLane / DownloadSession / artifact`继续拥有调度、priority、cancel、resume与字节状态；没有新增Reader私有下载器或第二套prefetch。
- `downloads`只增加platform direct transport capability，生产App在`downloads_bridge`注入`RhttpSourceResourceDirectTransport`；pure/test composition仍可使用既有Dart HttpClient。
- `downloads_bridge`没有新增`catalog/domain/transport`内部依赖；direct transport公开签名所需最小类型由`downloads`公共surface统一导出，保持既有package dependency contract。
- rhttp transport复用单一client、keep-alive、stream response和CancelToken；同一个scheduler `TaskControl`覆盖request/response生命周期，不拥有retry/prefetch策略。
- App在首帧后后台预热`Rhttp.init()`，避免第一次Reader current承担Rust runtime初始化。

## 依赖锁限制

`packages/downloads_bridge/pubspec.yaml`固定新增 `rhttp: 0.13.0`。当前环境没有Dart/Flutter/pub，无法可靠重算workspace `pubspec.lock`，本轮没有手工伪造archive hash或依赖解析结果。因此：

- 发行ZIP/Patch包含正确的pubspec依赖声明；
- `pubspec.lock`保持dev.177基线状态；
- 用户本地应用dev.178后必须先执行一次 `flutter pub get`，由真实Flutter/pub工具链解析并更新lock，再进行analyze/test/build。

这也是本轮唯一新增的构建验证缺口；不能将当前环境的静态gate结果表述成Flutter build-ready验证。

## 已实际通过的门禁

- `check_dart_structure.py`：343 Dart files / 129 test files。
- Dart directive order、documentation responsibility/current-code documentation。
- dev.123、138、139、161、174–178历史/ownership gates。
- Reader streaming、Pipeline demand stability、source-resource atomic binding、UI architecture。
- Venera bootstrap/Reader preflight/network/native-binary/response-header contracts。
- Mihon payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency closure、texture bridge Kotlin compile。
- `python3 -m py_compile tool/*.py`、全部shell syntax、native header。
- `check_repo.py`在package-boundary修正后仅停止于dev.177基线继承的 `third_party/source_archives/libwebp-1.6.0.zip` 缺失；未从旧包补入。

## Patch预回放

在写入本validation文件前，从全新dev.177项目根目录生成预Patch，并实际执行：

- `git apply --check --index`
- `git apply --index`

结果：1154个发行文件、21个实际修改/新增文件；missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本validation后的候选回放结果为1155个发行文件、22个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新dev.177重新生成正式Patch并再次执行`git apply --check --index` / `git apply --index`与完整file-set/content/mode比较，最终发行只在仍为1155 / 0 / 0 / 0 / 0时成立。
