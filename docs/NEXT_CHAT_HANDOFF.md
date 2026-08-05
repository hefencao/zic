# dev.131 后续交接

唯一后续基线：`zic_v0.31.0-dev.131_source-wake-retention-playback-rebuffer-closure.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0112-native-decode-priority-migration.md`
8. `docs/adr/0113-fresh-reader-texture-performance-core-deadline-wake.md`
9. `docs/adr/0114-source-wake-retention-and-single-startup-buffer.md`
10. `docs/audits/dev131-load-starvation-playback-rebuffer-audit.md`
11. `docs/audits/dev131-validation-results.md`

## 当前状态

- startup buffering gate 暂缓其他 DecodeId 时，source revision 保持 pending，不得标记为已消费。
- 同一 output 生命周期的 startup buffer 完成状态跨临时 transition/previous 保留；返回 current 不得中途重新缓冲。
- native active worker 已是 current 时 promotion 必须返回 none。
- fresh texture、performance-core affinity、partial source-growth、下载 handoff 和 7/5/3/2 水位保持。

## Patch

```bash
git apply --check --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.130_to_dev.131_source-wake-retention-playback-rebuffer-closure.patch"

git apply --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.130_to_dev.131_source-wake-retention-playback-rebuffer-closure.patch"
```

正式 ZIP 不包含 `.zic-workspace.json`，patch 不触碰本地配置。
