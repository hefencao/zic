# dev.233 validation results

- 输入设备证据：`zic-debug-trace-2026-08-12T01-05-57.jsonl`，7076 条事件；`taskFailed=0`，28 次 verified acquire alias 中 26 次 join / 2 次旧 multi-owner ambiguity，25 次 failed download state 全部为 cancellation/preemption。
- dev.205–dev.233 ownership/version/partial gates：PASS（29 项，8 workers）。
- `check_documentation.py`、`check_dart_structure.py`（352 Dart files / 131 test files）、Dart library directive、Pipeline runtime compile boundary、test quarantine、Pipeline demand stability、Reader streaming contract、UI architecture、Android runtime dependency、texture bridge Kotlin compile：PASS。
- Venera bootstrap contract 与 native header check：PASS。
- `tool/check.sh` 已纳入 dev.233 gate；但唯一 dev.232 基线本身缺少锁定的 `third_party/source_archives/libwebp-1.6.0.zip`，因此 `check_repo.py` 在全量入口最前面停止。未从旧包或其他基线补入该依赖。
- 当前环境缺少 Flutter SDK、Dart SDK 与 Cargo；因此 Flutter analyze/test、Dart行为测试、Android App build、Rust tests 不宣称通过。CMake/Ninja、Node、Java/Kotlin 可用，对应可执行专项已按上项运行。
- clean ZIP、baseline→dev.233 exact patch replay与逐文件内容/权限/type比较由发行外部报告记录；本文件不把未执行的toolchain验证写成通过。
