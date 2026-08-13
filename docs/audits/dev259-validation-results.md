# dev.259 验证结果

- 基线：`zic_v0.31.0-dev.258_decoder-playable-prefix-flow-authority.zip`。
- 候选：Source `0.31.0-dev.259` / App `0.31.0+259`。
- 变更范围：opaque URI runtime WebP transport-cost evidence、Pipeline bounded-flow激活、nonresident WebP late-join playable-prefix early publication、对应测试/治理；不修改3/7、5/3/2/1、NetLane 5+1、source-plan/provider/preemption参数。
- 08:03 Trace证据：59/59 `policyDecision`均`animatedFlowActive=false`且3/7 target全0，`mediaClassified=0`；初始11个download demand只有5个normal slot实际启动，全部target0。向前跳页时旧receiving task可rank0 retained，Trace有7次current preemption且partial均preserved idle；因此主现象是connection/admission饥饿，不是dev.258 playable-prefix floor不足。
- 工作树：dev.205–dev.259历史/ownership gates 55/55 PASS，`max_workers=8`；核心10/10 PASS；Dart structure 361 files / 135 test files。
- 候选patch reconstructed tree：dev.205–dev.259 55/55 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选full ZIP extracted tree：dev.205–dev.259 55/55 PASS（`max_workers=8`）+ 核心10/10 PASS。
- 候选`git apply --check --index`、`git apply --index`、第三份独立dev.258 packaged replay均PASS；patch/full/replay exact compare均`missing=0 extra=0 content=0 executable-bit=0 type=0`。
- 最终交付从原始dev.258再次重建并重复同等级门禁；full ZIP顶层目录使用dev.259权威名称。
- 完整`tool/check.sh`仅在基线缺少`third_party/source_archives/libwebp-1.6.0.zip`处停止；当前环境无Dart/Flutter/Cargo，不声明对应运行测试/build，Kotlin compile boundary实际PASS。
