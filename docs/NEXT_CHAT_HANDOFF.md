# dev.104 后续交接

唯一后续基线：`zic_v0.31.0-dev.104_startup-artifact-quantum-cursor-continuity.zip`。不得使用 dev.103 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree 覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/adr/0088-artifact-read-quanta-retained-cursor.md`
10. `docs/audits/dev104-startup-congestion-cursor-continuity-audit.md`
11. `docs/audits/dev104-validation-results.md`

## 当前主线

1. 在同一设备/fixture 采集 dev.104 Trace：刚进入、未稳定时切页、稳定后频繁切页。
2. 检查 `readSchedulerAcquires`、foreground acquire、最大 chunk wait 和 source first-chunk。
3. 检查新 current 的 frame 序列，禁止 retained frame 后再次上传 frame 0。
4. 继续定位 current decode failure 的 native 原因。
5. 运行 Flutter analyzer/tests 与 Android debug/release。

## 不可改变

- 下载 7/3；页面预解码 2/1；只上传 current/transition；lane 5/3/2；
- 两个进程期 Dart decode isolate；libwebp 帧内单线程；current 两个 successor；
- Reader 不拥有 session、transport、artifact、decode/upload lane、scheduler 或 texture；
- README、Architecture、Spec 不写单轮 Trace、验证结果或未验证推断。
