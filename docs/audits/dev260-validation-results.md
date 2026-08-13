# dev.260 验证结果

- 版本：Source `0.31.0-dev.260` / App `0.31.0+260`。
- 设备基线：09:00 Trace；page99 next1 target5在491,520 bytes主动suspend，约104ms后current重新open，同partial未失败/未丢失。
- 工作树验证：dev.205–260 历史/ownership gates 56/56 PASS（最多8 workers）；核心10/10 PASS；Dart structure 361 files / 135 test files。
- patch reconstructed tree：dev.205–260 56/56 PASS（最多8 workers）+ 核心10/10 PASS。
- full ZIP extracted tree：dev.205–260 56/56 PASS（最多8 workers）+ 核心10/10 PASS。
- exact replay：第三份独立 pristine dev.259 Git baseline 自执行 PASS；patch/full/replay exact compare 均为 missing=0 / extra=0 / content=0 / executable-bit=0 / type=0。
- 环境限制：`tool/check.sh` 当前仅因原 dev.259 基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` 停止；Dart/Flutter/Cargo 不可用，Kotlin compile boundary 已实际通过。
