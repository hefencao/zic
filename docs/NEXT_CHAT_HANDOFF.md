# dev.130 后续交接

唯一后续基线：`zic_v0.31.0-dev.130_retained-output-projector-compile-closure.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0112-native-decode-priority-migration.md`
8. `docs/adr/0113-fresh-reader-texture-performance-core-deadline-wake.md`
9. `docs/audits/dev129-reader-background-reentry-vibe-lifecycle-audit.md`
10. `docs/audits/dev130-retained-output-projector-compile-closure-audit.md`
11. `docs/audits/dev130-validation-results.md`

## 当前编译闭包

- `_RetainedAndroidTextureOutputFrame` 已从所有生产源码中完全移除。
- Android projector 只接受 `_AndroidTextureOutputFrame`。
- 不得通过重新定义空壳类型恢复跨 Reader retained output。
- dev.129 fresh texture、deadline wake 与性能核心 affinity 保持。

## Patch

```bash
git apply --check --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.129_to_dev.130_retained-output-projector-compile-closure.patch"

git apply --index \
  "$(python3 tool/workspace_config.py patch_dir --absolute)/zic_v0.31.0-dev.129_to_dev.130_retained-output-projector-compile-closure.patch"
```

正式 ZIP 不包含 `.zic-workspace.json`，patch 不触碰本地配置。
