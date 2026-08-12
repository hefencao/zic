# dev.231 validation results

- 00:19 dev.230真机Trace：7084 events；`verified-transfer-acquire-alias` 43次（21 promoted / 20 failed / 2 queued）；`taskFailed/sessionBusy/writerBusy`均为0；`restored-equivalent`继续命中，`skip-verified-equivalent-durable`出现12次。
- `python3 tool/check_documentation.py`：PASS。
- `python3 tool/check_dart_structure.py`：PASS（352 Dart files / 131 test files）。
- dev.205–dev.231相关ownership/version/partial gates：PASS（8 workers）。
- Reader streaming、Pipeline demand stability、UI architecture、test quarantine、Pipeline runtime compile boundary：PASS。
- dev.206 Kotlin facade stub及Android texture bridge Kotlin compile：PASS（仅stub unused-parameter warnings）。
- `TERM=xterm bash tool/check.sh`：仅因唯一dev.230基线缺少`third_party/source_archives/libwebp-1.6.0.zip`停止；未从历史包补入。
- 当前环境无Dart/Flutter SDK：新增Dart行为测试、Flutter analyze/tests与APK build未执行，不记为通过。
- pristine dev.230预冻结Patch replay：`git apply --check --index` / `git apply --index` PASS；missing/extra/content/executable-bit/type均为0。
- 最终完整ZIP与Exact Replay在发行冻结后再次独立验证；结果记录于外部validation与Exact Replay报告。
