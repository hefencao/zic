# dev.136 后续交接

唯一后续基线：`zic_v0.31.0-dev.136_catalog-weight-compile-cleanup.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
8. `docs/adr/0119-catalog-cache-weight-and-compatibility-cleanup.md`
9. `docs/audits/dev136-compile-and-dead-code-audit.md`
10. `docs/audits/dev136-validation-results.md`

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=136`。
- catalog metadata response 使用结构化 byte-weight，不使用固定权重或 JSON 临时序列化。
- `ResourceCacheCoordinator.responses` 和 composition-owned `ArtifactCacheManager` 仍是两个明确平面，不新增 UI 私有缓存。
- cold artifact handoff 使用 typed async owner；不要恢复无返回值 `catchError` 链。
- 无调用的 WebP-folder/ImageFolder App compatibility facade 已删除；单文件 WebP、ImageFolder 当前 owner API 保留。
- dev.135 稳定 cover/Venera/artifact identity 与 dev.134 Reader resource retention 保持。
- Native identity仍为 `zic-media-core-dev134-abi6-lib00121400`。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch 命令：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```

## 下一轮验证

- 使用真实 Flutter SDK 运行 analyzer、catalog/downloads/local_media_ui tests 和 App target tests。
- 只处理当前 dev.136 可复现错误；旧日志中当前接口已闭合的错误不得通过恢复兼容 facade 解决。
- 继续设备验证运行模式切换、封面冷启动和真实 E-Hentai 版本关系。
