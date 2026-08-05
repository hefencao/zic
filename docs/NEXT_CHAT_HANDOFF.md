# dev.138 后续交接

唯一后续基线：`zic_v0.31.0-dev.138_vibevenera-transition-first-frame.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
8. `docs/adr/0119-catalog-cache-weight-and-compatibility-cleanup.md`
9. `docs/adr/0120-progressive-home-cover-and-current-source-flow-pressure.md`
10. `docs/adr/0121-vibevenera-independent-transition-first-frame.md`
11. `docs/audits/dev138-vibevenera-switch-independence-audit.md`
12. `docs/audits/dev138-validation-results.md`

## 当前关键结论

- dev.137 的 `DownloadFlowGate` 是错误的第二套网络调度权威，已完全删除。
- Current 网络优先只由 NetLane reserved slot、priority migration 与 preemption 负责。
- transition depth=0 时独立执行 `t>0`，不等待 current `c>2`；获得一帧后恢复原 staged 水位。
- 首页分阶段发布与 DownloadJob 小块合并保留。

## 下一份 Trace

- target coverage 建立 transition 的时点；
- transition 的 `decodeRefill stage=t>0` 与 `firstFrameReady`；
- current `c>2` 和 transition 后续 `n>1/n>2` 的顺序；
- current/target `downloadStarted`、priority migration 与 source growth；
- 不应再出现 `downloadFlowPressure`。

## 约束

- 不缩小 7/3、7/5/3/2 或 5/3/2；
- 不在 Reader/App 新增网络调度、正文缓存或首帧锁；
- 不让 current holder depth 控制目标页网络资格；
- 正式 ZIP 不含 `.zic-workspace.json`；Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
