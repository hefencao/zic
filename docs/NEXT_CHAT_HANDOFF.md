# dev.103 后续交接

唯一后续基线：`zic_v0.31.0-dev.103_reader-reentry-platform-ack.zip`。不得使用 dev.102 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/adr/0087-reader-reentry-platform-presentation.md`
10. `docs/audits/dev103-reader-reentry-platform-audit.md`
11. `docs/audits/dev103-validation-results.md`

## 当前主线

1. 在同一设备和 WebP fixture 上分别采集首次进入与退出后再次进入的 dev.103 Trace。
2. 检查 `readerSessionDisposeStarted/Disposed`，确认旧 Reader 清理与新 Reader 建立的真实顺序。
3. 比较 `platformScheduleQueueMicros`、`channelDispatchMicros`、`presentationAckCreditMicros`、native decode 和 source wait。
4. 继续取得两次 decode failure 的 native frame/cycle/error 细节。
5. 运行 Flutter analyzer/tests 与 Android debug/release，解除静态未验证项。

## 不可改变

- 下载 7/3；页面预解码 2/1；只上传 current/transition；lane 5/3/2；
- 两个进程期 Dart decode isolate；libwebp 帧内单线程；current 两个 successor；
- Reader 不拥有 session、transport、artifact、decode/upload lane 或 texture；
- README、Architecture、Spec 不写单轮 Trace、验证结果或未验证推断。
