# dev.227 validation results

## 变更范围

- 修复verified physical alias后的source-request identity半迁移。
- `DownloadJob`显式接受provider `requestUri`；所有full open、Range probe、strong-validator resume和validatorless resume均使用该URI。
- physical `DownloadSession.id`继续只作为artifact/writer/hot-partial/resume continuity anchor。
- `DownloadTransferOwner`从preferred claim取得exact `DownloadId`，以同一个exact URI同时选择transport并传给`DownloadJob.requestUri`。
- 新增failed partial + equivalent new provider exact URI行为测试源码及dev.227静态闭包gate。
- 不修改NetLane、水位、retry、resident replay、chapter claim、durable persistence或late takeover compatibility范围。

## 真机证据

`zic-debug-trace-2026-08-11T15-29-22.jsonl`共6095条事件：

- `verified-transfer-acquire-alias`：13次，全部`joined-existing-physical`；目标状态为5 promoted / 1 receiving / 1 idle / 6 failed。
- `taskFailed`：43次，全部为`Failure(source): unsupported URI scheme: venera-resource`。
- 60个page host中33个dispose前`firstFrameReady=false`，最大生命周期约11.18秒。
- legacy `verified-equivalent-promotion-takeover`：0次。

源码审计确认owner已用provider exact URI选择transport，但`DownloadJob`真正open仍读取physical anchor `session.id.canonicalUri`，导致新版本consumer transport被要求打开旧版本runtime URI。

## 已执行验证

- `python3 tool/test_dev227_provider_request_identity.py`：PASS。
- `python3 tool/check_documentation.py`：PASS。
- `python3 tool/check_dart_structure.py`：PASS（352 Dart files / 131 test files）。
- `python3 tool/check_test_quarantine.py`：PASS。
- Reader streaming / pipeline demand stability / UI architecture：PASS。
- dev.205–dev.227相关ownership/version/partial gates：PASS（8 workers）；其中dev.206 Kotlin facade stub实际编译通过。
- debug trace filter / Venera network-cache contract：PASS。
- `git diff --check`：PASS。

## 工具链限制

- Dart SDK：不可用。
- Flutter SDK：不可用。
- Java / kotlinc：可用。
- 因此新增Dart behavior test源码未实际执行；未声称`flutter analyze`、Flutter tests或APK build通过。
- `bash tool/check.sh`仍在首个pinned source archive presence gate停止，因为唯一dev.226基线不含`third_party/source_archives/libwebp-1.6.0.zip`；未从历史版本或独立archive补入。

## 发行验证

预冻结 pristine dev.226 ordinary Patch 已实际执行 `git apply --check --index` / `git apply --index`，随后与候选树逐文件比较：

- missing=0
- extra=0
- content=0
- executable-bit=0
- type=0

最终冻结前的三路独立验证均已实际执行：

- ordinary pristine dev.226 Patch replay：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0。
- 完整 dev.227 ZIP 独立解压：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0。
- 第三份 pristine dev.226 Exact Replay v1：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0。

validation写入这些真实结果后，发行物再次从pristine dev.226冻结并重复相同比较。
