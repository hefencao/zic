# dev.258 验证结果

- 基线：`zic_v0.31.0-dev.257_local-completion-provider-admission.zip`。
- 候选：Source `0.31.0-dev.258` / App `0.31.0+258`。
- 变更范围：decoder playable-prefix evidence、physical DownloadSession evidence projection、flow gate/proof satisfaction、对应测试/治理；不修改3/7、5/3/2/1、NetLane/provider/source-plan策略。
- 05:29 Trace证据：`downloadPreempted/Failure(cancelled)/download-task-source-decode terminal failure`均为0；page206在205,860 bytes被ANMF `completedFrames=2`误停，但decoder frame0要求262,144 bytes，首次mount→first frame约2.451s；page207在245,760 bytes已真实decode前2帧，重新切入首帧约112ms。
- 工作树：dev.205–dev.258历史/ownership gates 54/54 PASS，`max_workers=8`；核心10/10 PASS；Dart structure 361 files / 135 test files。
- 候选patch reconstructed tree：dev.205–dev.258 54/54 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选full ZIP extracted tree：dev.205–dev.258 54/54 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选`git apply --check --index`、`git apply --index`、第三份独立dev.257 packaged replay均PASS；patch/full/replay exact compare均`missing=0 extra=0 content=0 executable-bit=0 type=0`。
- 最终交付从原始dev.257再次重建并重复同等级门禁；full ZIP顶层目录使用dev.258权威名称。
- 完整`tool/check.sh`仅在基线缺少`third_party/source_archives/libwebp-1.6.0.zip`处停止；当前环境无Dart/Flutter/Cargo，不声明对应运行测试/build，Kotlin compile boundary实际PASS。
