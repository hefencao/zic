# dev.137 后续交接

唯一后续基线：`zic_v0.31.0-dev.137_home-cover-primary-current-flow-pressure.zip`。

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
10. `docs/audits/dev137-home-cover-remote-webp-flow-audit.md`
11. `docs/audits/dev137-validation-results.md`

## 下一份 Trace

首页：

- `home-library-primary`、`home-library-enrichment`；
-第一条 `homeCoverRequested`；
- `homeCoverSourceReady` 与 `homeCoverFirstFrame`。

远程 Reader：

- `downloadFlowPressure` hold/release 与 `decodeDepth`；
- `bytesCommitted.chunks`、native/artifact ingress 时间；
- current `sourceLength/sourceSealed`、frame cadence 与后台 source read 吞吐。

## 约束

- 不缩小 7/3、7/5/3/2 或 5/3/2；
-不在 Reader/App 新增网络调度或正文缓存；
-正式 ZIP 不含 `.zic-workspace.json`；Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
