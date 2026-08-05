# dev.139 后续交接

唯一后续基线：`zic_v0.31.0-dev.139_current-code-documentation-realignment.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0117-reader-resource-session-retention-and-affinity-removal.md`
8. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
9. `docs/adr/0119-catalog-cache-weight-and-compatibility-cleanup.md`
10. `docs/adr/0121-vibevenera-independent-transition-first-frame.md`
11. `docs/adr/0122-current-reader-pipeline-authority-consolidation.md`
12. `docs/audits/dev139-current-code-documentation-audit.md`
13. `docs/audits/dev139-validation-results.md`

## 当前代码事实

- NetLane 是唯一网络调度权威；不存在 holder/playback 驱动的网络资格门控。
- encoded window 为前 7/后 3，深度 decode 角色为前 2/后 1，holder 最大水位为 7/5/3/2。
- transition depth=0 独立执行一帧 bootstrap；获得首帧后恢复 staged current/neighbor refill。
- holder-driven playback 缺帧时保留当前 output；没有 startup-buffer。
- Reader 退出后最多保留 1 个 idle chapter resource session、TTL 2 分钟；used texture 不保留。
- Android 使用默认 platform channel、单 blit lane和 fresh used texture lifecycle。
- response cache 与 page artifact cache 是两个权威平面；App/Reader没有私有正文 LRU。

## 下一步

- 优先完成 `IMPLEMENTATION_PLAN.md` 中的设备与完整工具链闭环。
- 新 Trace 重点观察 transition first frame、NetLane priority、source growth、holder depth、deadline/present 和 readerSession retain/reuse。
- 发现实现变化时先更新 Architecture/Spec/Status/Handoff，不允许核心文档继续描述已删除路径。

## 不可改变的稳定边界

- 不缩小 7/3、7/5/3/2 或 5/3/2 来掩盖问题；
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture 或 CPU affinity；
- 不在 Reader/App 新增 transport、正文缓存、cursor、frame 或 session 所有权；
- 正式 ZIP 不含 `.zic-workspace.json`，Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
