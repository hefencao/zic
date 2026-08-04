# dev.127 后续交接

唯一后续基线：`zic_v0.31.0-dev.127_startup-buffer-refill-closure.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0110-startup-playback-buffer-deadline-lead.md`
8. `docs/adr/0111-startup-buffer-staged-refill-closure.md`
9. `docs/audits/dev127-startup-buffer-refill-deadlock-audit.md`
10. `docs/audits/dev127-validation-results.md`

## 下一份 Trace

重点检查：

- `playbackBufferingOutstandingCount` 必须为 0；
- waiting 到 ready 的耗时与 targetDepth；
-同一 current 是否按需出现 `c>2 → c>4 → c>6`；
- ready 后邻页 refill 是否恢复；
- frame 0 仍立即显示，后续持续播放；
- source/decode/upload/present failure 是否为 0。

## Patch

应用命令直接使用本地 resolver，不在聊天中引入 `PATCH_DIR`：

```bash
git apply --check --index   "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.126_to_dev.127_startup-buffer-refill-closure.patch"

git apply --index   "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.126_to_dev.127_startup-buffer-refill-closure.patch"
```

正式 ZIP 不包含 `.zic-workspace.json`，patch 不触碰本地配置。
