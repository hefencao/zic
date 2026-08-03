# dev.102 后续交接

唯一后续基线：`zic_v0.31.0-dev.102_async-texture-shared-artifact-read.zip`。不得使用 dev.101 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/adr/0086-async-texture-schedule-and-shared-artifact-read.md`
10. `docs/audits/dev102-test-async-schedule-artifact-read-audit.md`
11. `docs/audits/dev102-validation-results.md`

## 当前主线

1. 运行 Flutter analyzer/tests 和 Android debug/release，确认 quarantine 与 cold-open 编译闭包。
2. 在同一设备/fixture 采集 dev.102 Trace，验证异步 schedule 后的前帧长尾。
3. 检查 `readSchedulerWaitMicros`、priority 和跨 session source-read 并发是否符合 5 总槽、1 foreground 保留槽。
4. 为两次 current decode failure 增加或取得 native 错误细节。
5. 为 `Q-001` 至 `Q-003` 建立可控 owner/facade harness。

## 文档规则

- README 不写版本内容。
- Architecture 不写 Trace、测试结果或未验证推断。
- Spec 只写规范，不声明实现通过。
- Plan 只写未完成工作。
- Status 只写当前快照。
- 单轮证据只写入 audit。
- 只有稳定所有权或长期合同变化才修改 Architecture/Spec。

## 不可改变

- 下载 7/3；页面预解码 2/1；只上传 current/transition；lane 5/3/2；
- 两个进程期 Dart decode isolate；libwebp 帧内单线程；current 两个 successor；
- Reader 不拥有 session、transport、artifact、decode/upload lane 或 texture。
