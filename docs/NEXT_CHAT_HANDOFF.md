# dev.135 后续交接

唯一后续基线：`zic_v0.31.0-dev.135_unified-version-stable-cache-identity-reuse.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0117-reader-resource-session-retention-and-affinity-removal.md`
8. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
9. `docs/audits/dev135-cache-identity-cover-startup-audit.md`
10. `docs/audits/dev135-validation-results.md`

## 当前实现

- Android debug/profile/release 共用 `dev.zic.zic`、`versionName=0.31.0`、`versionCode=135`，无 build-type application/version suffix。
- 封面 key 为 `source + canonical comic + cover role`；URL/token 只用于真实请求。首页封面 request identity 只跟随稳定漫画 identity。
- 旧 URL-derived 封面缓存只单向迁移到稳定 key，新网络正文不双写。
- Venera comic/chapter ID 新 payload 不含可变展示字段；旧 payload 仍可解码。
- `ResourceCacheCoordinator.responses` 统一管理封面/详情/章节元数据/搜索；composition-owned `ArtifactCacheManager` 统一管理 Reader artifact。不要物理合并二者或新增 UI 私有缓存。
- `ArtifactCacheManager` 支持显式 alias/rekey；`VerifiedArtifactReusePlan` 只按 checksum、E-Hentai image key 或唯一 hash 建立页面复用，用户确认的跨源迁移已使用 existing-only alias。
- E-Hentai 新旧 gallery/version 的可信关系发现尚未接入生产来源；严禁标题/作者/页码猜测。
- dev.134 Reader 资源会话 retention、holder playback、单 blit、7/3、7/5/3/2 保持。
- Native identity 仍为 `zic-media-core-dev134-abi6-lib00121400`。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```

## 下一轮设备验证

- debug/profile/release 模式切换不卸载且数据保留。
- 冷启动封面区分 stable hit、legacy migration、persistent file hit 与 network miss。
- 真实 E-Hentai 版本关系接入后，检查 alias/rekey 命中、歧义页拒绝和历史下载/阅读状态兼容。
- 不要修改精确 DownloadId 或使用标题相似度自动复用。
