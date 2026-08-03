# dev.101 后续交接

唯一后续基线：`zic_v0.31.0-dev.101_documentation-boundary-schedule-timing.zip`。不得使用 dev.100 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/audits/dev101-documentation-trace-audit.md`
10. `docs/audits/dev101-validation-results.md`

## 当前主线

1. 在 Android 真机采集包含 `platformScheduleQueueMicros` 和 `platformScheduleCallMicros` 的新 Trace。
2. 用 `tool/analyze_frame_pipeline_trace.py` 判断 platform-thread queue、native decode、channel dispatch 和 source stream 的真实占比。
3. 运行 Flutter analyzer/tests、Android debug/release，并逐项处理失败。
4. 为 `Q-001` 至 `Q-003` 建立可控 owner/facade harness，解除 quarantine。

## 文档规则

- README 不写版本内容。
- Architecture 不写 Trace、测试结果或未验证推断。
- Spec 只写规范，不声明实现通过。
- Plan 只写未完成工作。
- Status 只写当前快照。
- 单轮证据只写入 audit。
- 只有稳定所有权或长期合同变化才修改 Architecture/Spec。

## 不可改变

- 下载 7/3；
- 页面预解码 2/1；
- 只上传 current/transition；
- lane 5/3/2；
- 两个进程期 Dart decode isolate；
- libwebp 帧内单线程；
- current 两个 successor；
- Reader 不拥有 session、transport、artifact、decode/upload lane 或 texture。
