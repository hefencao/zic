# dev.128 后续交接

唯一后续基线：`zic_v0.31.0-dev.128_native-decode-priority-migration.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0110-startup-playback-buffer-deadline-lead.md`
8. `docs/adr/0111-startup-buffer-staged-refill-closure.md`
9. `docs/adr/0112-native-decode-priority-migration.md`
10. `docs/audits/dev128-native-decode-priority-migration-audit.md`
11. `docs/audits/dev128-validation-results.md`

## 下一份 Trace

重点检查：

- `decodePriorityPromotionCount`、queued/active 分类；
- 页面升为 current 后，同 identity 的 frame 0 延迟；
- 已完整 source 的 current 不再 `firstFrameReady=false` 后 dispose；
- retained output 后 authoritative successor 是否及时出现；
- `playbackBufferingOutstandingCount` 仍为 0；
- task failure、duplicate cursor 或 source reset 是否为 0。

## Patch

应用命令直接使用本地 resolver，不在聊天中引入 `PATCH_DIR`：

```bash
git apply --check --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.127_to_dev.128_native-decode-priority-migration.patch"

git apply --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.127_to_dev.128_native-decode-priority-migration.patch"
```

正式 ZIP 不包含 `.zic-workspace.json`，patch 不触碰本地配置。
