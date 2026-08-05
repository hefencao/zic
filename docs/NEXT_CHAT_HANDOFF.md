# dev.134 后续交接

唯一后续基线：`zic_v0.31.0-dev.134_reader-resource-session-retention-affinity-removal.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0115-vibevenera-holder-playback-local-hot-bytes.md`
8. `docs/adr/0116-vibevenera-direct-byte-and-single-blit-reentry.md`
9. `docs/adr/0117-reader-resource-session-retention-and-affinity-removal.md`
10. `docs/audits/dev134-reader-resource-session-retention-audit.md`

## 当前实现

- Reader 退出只释放 binding、page projection、playback wake 与 used texture。
- 同章同 source revision 的完整 Pipeline resource session 进入最多 1 项、2 分钟 idle lease；重入复用原 DownloadSession/native source/DecodeSession。
- retention key 使用 loader URI/revision；每次 build 新建的 LoaderTransportSource object 不会导致 miss。
- 不同 chapter/revision/configuration、TTL 到期或容量淘汰时完整 dispose。
- dev.129/dev.133 CPU affinity 已删除；`workerPlacementStatus` 仅保留 schema 兼容并为 0。
- dev.133 单 platform channel/单 blit lane 保留；used texture 不跨 Reader。
- 下载 7/3、动画水位 7/5/3/2、两个 worker、holder playback、partial source-growth 保持。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```

## 下一轮设备验证

- 同页重入应出现 `readerSessionRetained`/`readerSessionReused`，不应再创建新的 pipeline-reader session。
- retained interval 内不应再出现 18.3 MiB current `memory-direct` ingress 或整组 9 个下载任务重启。
- 检查 fresh texture 下的 platform present 长尾与 holder 连续播放；不要重新引入 retained used texture。
- TTL、切章和 source revision 变化必须触发真实销毁与冷启动。
