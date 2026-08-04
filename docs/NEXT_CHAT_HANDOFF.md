# dev.123 后续交接

唯一后续基线：`zic_v0.31.0-dev.123_current-download-handoff-vertical-composition.zip`。不得使用 dev.122 或更早 ZIP、旧工作树或补丁树。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0106-retained-transfer-partial-prefix-playback.md`
9. `docs/adr/0107-active-rank-handoff-vertical-composition.md`
10. `docs/audits/dev123-download-preemption-vertical-composition-audit.md`
11. `docs/audits/dev123-validation-results.md`

## 下一份 Trace

重点检查：

- `downloadStarted.priority/effectivePriority/handoffActive`；
- current 提权到实际开始的延迟；
- 被抢占任务是否复用 committed partial；
- global/source bucket active 与稳定上限；
- Flutter build/layout p50/p95、页面 host mounted/disposed；
- ratio 更新前后是否重复调用 pageBuilder。

## 保持边界

7/3、5/3/2、动画 7/5/3/2、静态一帧满足、30 帧 partial loop、retained transfer/output、统一 cache/session/texture 所有权不变。VibeVenera 参考源码继续只读。
