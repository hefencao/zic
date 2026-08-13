# dev.252 验证结果

- 唯一代码基线：`zic_v0.31.0-dev.251_consumer-paced-flow-control-fallback.zip`。
- 真机输入：`zic-debug-trace-2026-08-12T23-17-50.jsonl`。
- work tree：dev.205–252历史/ownership gate 48/48 PASS（max-workers=8）；核心门禁10/10 PASS。Dart structure为361个Dart文件、135个test文件。
- `tool/check.sh`仍只在基线缺少`third_party/source_archives/libwebp-1.6.0.zip`时入口停止；未从旧包或Library补入。
- 当前环境无Dart/Flutter/Cargo，因此不得宣称Dart行为测试、Flutter analyze/build或Rust tests已执行；Kotlin compile boundary实际通过。
- exact patch replay、full ZIP与发行树复验在发行冻结步骤完成后由外部validation报告补全。
