# dev.126 后续交接

唯一后续基线：`zic_v0.31.0-dev.126_startup-playback-buffer-deadline-lead.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0110-startup-playback-buffer-deadline-lead.md`
8. `docs/audits/dev126-startup-playback-cadence-audit.md`
9. `docs/audits/dev126-validation-results.md`

## 下一份 Trace

重点检查：

- `playbackBuffering` waiting/ready 的间隔、targetDepth 与 successorDepth；
- frame 0 是否仍在启动缓冲前立即显示；
- ready 前 decode refill 是否仅 current，ready 后 next/next+1 是否恢复；
- `playbackLeadMicros`、deadline miss、visible frame interval；
- native decode 与 platform present 是否仍为主要瓶颈。

## 交付

继续交付完整 ZIP、基线到新版本 patch、SHA256SUMS。正式 ZIP 不包含 `.zic-workspace.json`，patch 不触碰本地配置。
