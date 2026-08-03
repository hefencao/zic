# dev.100 后续交接

唯一后续基线：`zic_v0.31.0-dev.100_test-quarantine-texture-schedule.zip`。不得以 dev.99 或更早 ZIP、旧工作树、未登记 skip、记忆源码或可变 libwebp tree 覆盖。

必读：

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0084-test-quarantine-and-texture-schedule-reply.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/audits/dev100-test-quarantine-playback-audit.md`
10. `docs/audits/dev100-validation-results.md`

下一份设备 Trace 先运行：

```bash
python3 tool/analyze_frame_pipeline_trace.py zic-debug-trace-*.jsonl
```

重点检查：

- `recordedDominantStageCounts` 仅用于兼容旧 trace；判断瓶颈使用归一化后的 `dominantStageCounts`。
- `decodedLeadMicros` 是正常 successor 提前量，不参与 dominant。
- `uploadBackpressureMicros` 才表示超过前帧 deadline 后仍等待 upload。
- dev.100 Android path 应使 `platformResultDispatchMicros` 接近 0；platform thread 的真实等待应计入 `platformScheduleMicros`。
- 若 `platformSchedule` 仍高，继续检查 Android UI/platform thread 负载，不能把它误归给 libwebp。
- quarantined test 只能按 `docs/testing/TEST_QUARANTINE.md` 的解除条件恢复；不得增加匿名 skip。

不可改变：下载窗口 7/3、页面预解码 2/1、只上传 current/transition、lane 5/3/2、两个进程期 Dart decode isolate、libwebp 帧内单线程、两帧 successor，以及 Reader 不拥有 session/transport/artifact/texture。

历史验证证据仍保留在：`docs/audits/dev97-validation-results.md`、`docs/audits/dev98-validation-results.md`、`docs/audits/dev99-validation-results.md`。
