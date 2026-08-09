# dev.176 验证结果

## 基线与环境

- 唯一代码基线：`zic_v0.31.0-dev.175_venera-transport-native-ingress-preemption.zip`。
- 输入设备证据：`zic-debug-trace-2026-08-09T00-33-35.jsonl`，共3099条事件。
- 发行版本：Source `0.31.0-dev.176`，Android `versionCode=176`。
- 当前环境有 Python/Git/Kotlin/JVM/Node；没有 Dart/Flutter/Cargo与完整Android SDK/NDK，因此不宣称 Dart/Flutter行为测试、Rust tests、analyzer或APK build已执行通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py`仅在该既有缺件处停止，未从旧版本补入。

## Trace结论

- NetLane handoff仍正常：current可见 `priority=1000/globalActive=6/handoffActive=1`。
- origin open长尾仍存在，样本包括约5.18s、8.22s、8.30s、8.86s、17.74s、19.28s；旧下载在调度层进入cancelled后，其origin stream仍可稍后才以 `completed:false`收尾。
- dev.175 native锁修复生效：`bytesCommitted.maxNativeIngressMicros`中位约60us、p90约205us，显著低于上一轮十几/数十毫秒尖峰。
- 剩余artifact commit常见约2–5ms、样本最大约6.4ms；代码审计定位到partial append仍同步执行纯Dart `Crc32.add()`。
- 唯一network taskFailed为远端连接接收中断，不新增retry owner。

## 本轮验证

已通过：

- `check_dart_structure.py`：342 Dart files / 129 test files。
- documentation responsibility与dev.139 current documentation。
- dev.161、162、170–176受影响ownership/protocol gates。
- dev.174/175 current/Venera preemption gates。
- Reader streaming、Pipeline demand、source-resource atomic binding、UI architecture。
- Venera bootstrap/network/native-binary/Reader-preflight。
- Mihon payload Context Kotlin compile、ABI routing、chapter contract。
- Android texture bridge Kotlin compile、Python compile与shell syntax/native header。

新增但因环境未执行的Dart行为测试：

- controlled source response已进入stream后，scheduler cancel必须在服务器下一chunk前终止client stream并abort upstream。
- partial artifact append期间checksum未materialize；seal后必须得到标准CRC32并通过expected checksum校验。

## Repository check

`python3 tool/check_repo.py`仅停止于基线缺失的 pinned libwebp archive，无其它repo错误。

## Patch回放

加入本validation后的候选Patch从全新dev.175实际执行 `git apply --check --index` 与 `git apply --index`；共1146个发行文件、17个实际修改/新增文件，missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结，正式Patch必须再次从全新dev.175得到同一1146 / 0 / 0 / 0 / 0结果。
