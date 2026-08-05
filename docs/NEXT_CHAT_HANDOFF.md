# dev.132 后续交接

唯一后续基线：`zic_v0.31.0-dev.132_vibevenera-holder-playback-local-hot-bytes.zip`。不得使用旧工作树或重放更早 patch。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0112-native-decode-priority-migration.md`
8. `docs/adr/0113-fresh-reader-texture-performance-core-deadline-wake.md`
9. `docs/adr/0115-vibevenera-holder-playback-local-hot-bytes.md`

## 当前实现

- dev.126–dev.131 startup-buffer gate 已由 ADR 0115 取代。播放消费 holder 已有帧；缺帧时保留当前 output，producer 新帧到达后唤醒 upload。
- NativeCursor 首帧 batch=1，current 后续 batch<=2；两个 native worker 不变。
- 完整本地不可变页面字节由 composition-owned `ArtifactCacheManager` 保留，跨 Reader session 按 DownloadId 命中；Reader/App 无私有字节缓存。
- 下载窗口 7/3、staged 水位 7/5/3/2、静态一帧满足、partial source-growth、fresh texture 生命周期保持。
- Android native identity 仍为 `zic-media-core-dev129-abi6-lib00121200`。
- 正式 ZIP 不含 `.zic-workspace.json`。Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```

## 下一轮设备验证

- 后台重入同页应出现 `artifact-byte-cache`，而不是重新读取完整 `content://` origin。
- 新运行时不应产生新的 `playbackBuffering` 或 `decode-startup-deferred`。
- 检查播放饥饿时当前 texture 保持、producer 唤醒后恢复，且无几帧播放后长停顿。
- 检查 current 双帧批量 decode 后 worker dispatch/round-trip 长尾是否下降。
