# dev.245 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.244_transport-cursor-provider-stability.zip`。
- 真机输入：`zic-debug-trace-2026-08-12T10-54-55.jsonl`。
- 当前候选：Source `0.31.0-dev.245` / App `0.31.0+245`。

## 变更范围

production只修改最终图片NetLane admission/preemption：删除normal-pressure主动preemption；current优先直接借唯一reserved +1；只有normal+reserved都饱和才允许current按统一rank preempt；Reader active priority下调增加200ms bounded demotion-preemption grace并由NetLane自身到期repump。restart-cost公式、DownloadSession/partial、provider task-lifetime、双进度、DecodeSession与Venera单context controlled gate不变。

## 已执行验证

- dev.205–dev.245 history/ownership gates：41/41 PASS，最多8 workers。
- documentation responsibility：PASS。
- Dart structure：PASS（357 files / 133 test files）。
- Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming/output、UI architecture、test quarantine：PASS。
- Android runtime dependency mutation check、texture bridge Kotlin compile：PASS。
- dev.139 current-documentation consistency：PASS。
- `bash tool/check.sh`实际执行，仍在第一项因dev.244基线缺失`third_party/source_archives/libwebp-1.6.0.zip`退出；未从历史包或文件库补入。

当前环境无 Dart/Flutter/Cargo；有Kotlin compiler。因此不宣称Dart行为测试、`flutter analyze`/build或Rust tests已运行。新增Dart行为回归已写入仓库，需用户本地工具链/真机继续验证。

## 真机待验证

下一Trace应重点确认：780/800/820/900不再产生最终图片`downloadPreempted`；normal5满时第一个current直接以handoffActive=1启动而无victim cancel；快速跨session/session role切换时recently-demoted active至少越过200ms抖动窗口，重新获得demand则原位提权。若5+1持续饱和超过grace，current仍允许按统一effective rank进行真正preemption。
