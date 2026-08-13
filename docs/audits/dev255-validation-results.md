# dev.255 验证结果

## 基线与输入

- 唯一基线：`zic_v0.31.0-dev.254_decode-ingress-epoch-bounded-flow-suspension.zip`
- 真机输入：`zic-debug-trace-2026-08-13T03-19-56.jsonl`
- 候选：Source `0.31.0-dev.255` / App `0.31.0+255`

## 变更范围

只收口scheduler cancellation与authoritative partial lifecycle：typed cancellation不得进入DownloadState.failed；DownloadJob各attempt error closure统一flush/pause；DownloadSession.fail提供最终typed-cancel guard；preemption telemetry增加只读partial preservation事实。3/7、scrubbing、动画frame credit、NetLane 5+1/current candidate/restart-cost、decode/source generation均不改。

## 可执行验证

- dev.205–dev.255历史/ownership gates：51/51 PASS，`max_workers=8`。
- 核心门禁：10/10 PASS。
- documentation responsibilities：PASS。
- Dart structure：PASS，361 Dart files / 135 test files。
- Pipeline runtime compile boundary：PASS。
- Pipeline demand stability：PASS。
- Reader streaming/output contract：PASS。
- UI architecture contract：PASS。
- test quarantine ownership：PASS。
- Android runtime dependency check：PASS。
- Android texture bridge Kotlin compile：PASS。
- dev.139 current-documentation consistency：PASS。
- 稳定文档预算继续为Architecture 420 / Plan 180 / Handoff 80行。

## 完整入口

`bash tool/check.sh`仍在第一项因唯一dev.254基线缺少`third_party/source_archives/libwebp-1.6.0.zip`退出；本轮未从历史包或文件库补该source archive。

当前环境无Dart/Flutter/Cargo；不得把以上静态/ownership gate解释成已执行Dart behavior tests、Flutter analyze/build或Rust tests。Kotlin compiler-backed boundary check实际执行并通过。

## 最终发行验证

- 第二份独立dev.254 Git baseline：`git apply --check --index` PASS；`git apply --index` PASS。
- packaged `replay.py`在第三份独立dev.254 baseline：PASS，`exact_patch_replay=OK`。
- patch reconstructed tree：dev.205–255 51/51 PASS（8 workers）+ 核心10/10 PASS。
- full ZIP extracted tree：dev.205–255 51/51 PASS（8 workers）+ 核心10/10 PASS。
- patch/full/replay relative target：`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。

写入本结果后已从原始dev.254基线重新冻结最终manifest/patch/full ZIP/replay；最终patch reconstructed tree与full ZIP extracted tree再次分别完成dev.205–255 51/51 + 核心10/10，packaged replay再次在独立dev.254 baseline通过。最终发行外部validation/SHA以该冻结manifest为准。
