# dev.181 验证结果

## 环境与基线

- 唯一代码基线：`zic_v0.31.0-dev.180_openjdk25-previous-window-ownership.zip`。
- 当前发行版本：Source `0.31.0-dev.181`，Android `versionCode=181`。
- 输入设备证据：`zic-debug-trace-2026-08-09T05-00-31.jsonl`。
- 只读对照：文件库权威 `vibevenera-master.zip`。
- 当前环境有 Python、Git、Node、OpenJDK 21、Kotlin/JVM 1.9；没有 Flutter/Dart/Cargo/完整Android SDK，因此不宣称 analyzer、Dart/Flutter tests、APK build或Rust tests已执行通过。
- dev.180基线继续缺 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py`仅在该既有缺件处停止，本轮未从旧包补入。

## 新 trace 结论

- trace共7804条事件。
- cache/hot revisit路径已明显健康：部分page host mount到`firstFrameReady`仅约14.5ms，其他cache页多为几十到数百毫秒。
- origin current仍存在秒级长尾。典型page62在NetLane已`priority=1000/globalActive=6/handoffActive=1`后启动，但origin `source-loader` open约8.58秒；`sourceReady`后约90ms即可首帧。因此decode/upload不是该慢页的主要端到端等待。
- rhttp logical framing已经生效：origin sourceRead可见约64KiB首块、约256KiB continuation。本轮不再修改framing、水位或并发参数。
- frame pipeline还显示已有预decode可跨很长时间保留，在目标页进入transition/current后再上传；因此“所有切页都重新decode”不成立，不能以重建第二套Reader cache作为修复方向。

## 根因与实现验证

代码审计确认生产`PipelineReaderSession._transportFor()`在启用artifact cache时总返回`ArtifactCacheTransport`。dev.180该wrapper只实现`Transport`，使`DownloadJob`无法看到`ControlledTransport` capability；cache miss又调用普通`fallback.open()`。因此dev.175建立的TaskControl链在生产read-through seam被擦除。

本轮实现：

- `ArtifactCacheTransport implements ControlledTransport`。
- ordinary `open()`委托`openControlled(..., control:null)`。
- cache lookup / foreground read边界尊重cancellation。
- cache miss时若fallback为`ControlledTransport`，原样传递同一TaskControl；cancelled cache miss不得打开origin。
- cache scheduler在没有composition demand callback时可使用control实时priority作为capability fallback。
- origin artifact/sourceRead telemetry新增`controlledFallback`和priority，便于下轮真机确认current=1000是否真正穿过read-through。
- 未引入整章Venera request-plan预解析；当前VibeVenera同样在单图下载附近执行image-loading config。

## 实际通过

- dev.75–97、dev.99–181历史ownership gates均明确PASS；dev.98仅因基线缺pinned libwebp archive排除。
- `check_dart_structure.py`：345 Dart files / 130 test files。
- Dart library directive order、documentation/current-documentation gates。
- Reader streaming、Pipeline demand stability、source-resource atomic binding、UI architecture。
- Venera bootstrap、Reader preflight、network policy、native-binary、response headers。
- Mihon entry、Payload Context实际Kotlin编译、ABI routing、split classloader、read-only payload、chapter contract。
- Android runtime dependency closure/mutations、texture Kotlin compile。
- Python bytecode syntax、`bash -n tool/check.sh`、native-header检查。

## 未执行

当前环境缺Flutter/Dart，因此新增的`artifact_cache_transport_test.dart`两个行为回归没有实际运行；它们已经纳入源码：

1. cache miss必须把同一个scheduler control传入controlled origin fallback；
2. 已cancelled的controlled cache miss不得打开origin。

## Repository check

`python3 tool/check_repo.py`只停止于继承缺件：

`third_party/source_archives/libwebp-1.6.0.zip`

## Patch预回放

写入本validation前，从全新dev.180生成预Patch，并实际执行：

- `git apply --check --index`
- `git apply --index`

预回放包含1169个发行文件、15个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本validation后的候选回放包含1170个发行文件、16个实际修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式Patch并从全新dev.180再次执行`git apply --check --index` / `git apply --index`与完整manifest/mode比较。
