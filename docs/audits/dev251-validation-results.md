# dev.251 验证结果

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.250_byte-response-flow-control-api-closure.zip`。
- 设备Trace：`zic-debug-trace-2026-08-12T16-42-06.jsonl`，共5805条事件。
- Trace中`transport-flow-control`真实`paused` 35次、`resumed` 22次；`downloadPreempted` 9次且9/9 victim此前均处于flow-paused。正frame-credit启动任务里未pause的主要样本为persistent artifact-cache本地读取，不应伪装为网络backpressure。

## 改动范围

- `ByteResponseFlowControl`增加`consumerPacing`，表示同一body可安全停止consumer迭代并稍后继续，但不承诺节省已经materialize/buffer的上游字节。
- runtime source fallback与generic `LoaderTransport`声明该能力；direct HttpClient/rhttp继续使用`streamBackpressure`。
- `DownloadJob`对`bodyAuthority=source`且capability非`none`统一执行原frame credit；真实pause记录`paused/resumed`，伪pause记录`pseudo-paused/pseudo-resumed`。
- artifact-cache/resident、3/7、5/3/2/1 frame target、NetLane 5+1、partial/progress/provider lifetime均未修改。
- 本轮没有把flow-paused task排除NetLane active计数；该改动需要完整resume-permit仲裁，避免多个paused task同时恢复后突破并发上限。

## 工作树验证

- dev.205–251历史/ownership gate：47/47 PASS，`max_workers=8`。
- 核心门禁：10/10 PASS。
- Dart structure：361 Dart files / 135 test files。
- documentation responsibility：PASS。
- Pipeline runtime compile boundary / demand stability / Reader streaming / UI architecture / quarantine / Android dependency / Kotlin texture compile / dev.139 consistency：PASS。

## 完整入口

`tool/check.sh`仍在第一步因唯一dev.250基线缺少`third_party/source_archives/libwebp-1.6.0.zip`停止；未从旧包或文件库补入。

## 未执行

当前环境没有Dart/Flutter/Cargo，因此新增Dart行为测试源码未实际执行，Flutter analyzer/build与Rust tests也不宣称通过。Kotlin compile boundary实际执行并通过。
