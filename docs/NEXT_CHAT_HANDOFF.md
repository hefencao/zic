# dev.125 后续交接

唯一后续基线：`zic_v0.31.0-dev.125_background-retained-output-partial-source-growth.zip`。不得使用 dev.124 或更早 ZIP、旧工作树或补丁树。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0108-startup-current-prefix-exact-output-prewarm.md`
9. `docs/adr/0109-background-retained-output-partial-source-growth.md`
10. `docs/audits/dev125-background-resume-retained-output-partial-failure-audit.md`
11. `docs/audits/dev125-validation-results.md`

## Patch 交付

- 每轮生成上一完整 ZIP 到新版本的 `git apply --index` patch。
- patch 目录由 `ZIC_PATCH_DIR` 或用户本地 `.zic-workspace.json` 提供。
- `.zic-workspace.json` 不属于发行包，不得被 patch 创建、修改或删除。

## 下一份 Trace

重点检查 `retainedOutputRestoreCount`、恢复首帧、后续 authoritative frame 替换、`decodeSourceGrowthWaitCount` 与 `decodeRecoveryCount`。

## 保持边界

7/3、5/3/2、current handoff、动画 7/5/3/2、静态一帧、30 帧 partial loop、统一 cache/session/texture 所有权不变。VibeVenera 参考继续只读。
