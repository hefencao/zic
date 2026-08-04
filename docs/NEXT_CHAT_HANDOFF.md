# dev.124 后续交接

唯一后续基线：`zic_v0.31.0-dev.124_startup-current-prefix-exact-output-prewarm.zip`。不得使用 dev.123 或更早 ZIP、旧工作树或补丁树。

## 必读

1. `AGENTS.md`
2. 本文件
3. `.zic-workspace.json`
4. `docs/DOCUMENTATION_POLICY.md`
5. `docs/ARCHITECTURE.md`
6. `docs/SPEC.md`
7. `docs/IMPLEMENTATION_STATUS.md`
8. `docs/IMPLEMENTATION_PLAN.md`
9. `docs/adr/0107-active-rank-handoff-vertical-composition.md`
10. `docs/adr/0108-startup-current-prefix-exact-output-prewarm.md`
11. `docs/audits/dev124-startup-current-prefix-audit.md`
12. `docs/audits/dev124-validation-results.md`

## Patch 交付

- 每轮必须生成上一完整 ZIP 到新版本的 patch，格式兼容 `git apply --index`。
- patch 输出目录读取 `python3 tool/workspace_config.py patch_dir --absolute`。
- 不在聊天或脚本中另行硬编码不同 patch_dir。

## 下一份低性能设备 Trace

重点检查：

- `mountToFirstFrameMicros`；
- 首帧前 local `bucketActive/bucketLimit`；
- 首个 frame 的 source wait、native/dispatch decode、output prepare、present；
- `textureLeaseReused` 与 `surfaceReconfigureCount`；
- 首帧后 local cap 恢复 2，next 预下载继续。

## 保持边界

7/3、全局/remote 5、本地稳定 2、5/3/2、动画 7/5/3/2、静态一帧满足、30 帧 partial loop、retained transfer/output、统一 cache/session/texture 所有权不变。VibeVenera 参考源码继续只读。
