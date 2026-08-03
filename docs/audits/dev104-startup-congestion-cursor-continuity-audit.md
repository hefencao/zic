# dev.104 启动拥堵与 retained cursor 连续性审计

- 基线：`0.31.0-dev.103`
- 输入：`zic-debug-trace-2026-08-03T10-47-52.jsonl`
- 状态：修复前审计；本文件保存单轮设备证据，不构成稳定 Architecture 或 Spec。

## 问题清单

### 编译错误

- 本轮输入未附带新的编译报告；先保持 dev.103 已建立的编译闭包。

### 产品错误

1. Reader 初次进入后前若干帧极度卡顿；等待一段时间后同一 Reader 内频繁切页明显更流畅。
2. 新页有时只呈现首帧但不继续播放，必须切到其他页再切回才恢复。
3. Trace 中存在 current decode failure；本轮不把所有卡顿统一归因于 native decode。

### 性能问题

1. 设备 Trace 记录 36 条 persistent artifact stream；进程级并发达到 scheduler 上限 5。
2. current 约 17–21 MiB 页面读取时，最多同时存在 4 条 background 全量 session-copy。多条 stream 持续约 1.8–2.5 秒，scheduler wait p95 约 0.95 秒。
3. 当前 `ArtifactCacheReadScheduler` 的 lease 覆盖整个 artifact stream。background 一旦获得槽位，直到完整文件复制结束才释放，后续角色晋升只能影响尚未开始的 stream，不能重新调度已启动流。
4. 这会在启动阶段把 current、transition 和多个 near/background 的完整本地复制同时灌入 ingress、artifact writer、decode 和 upload 链，符合“水位达到后整体变顺”的拥堵特征。

### 测试错误

- 现有 scheduler 测试只证明“整条 stream 永久保留一个 foreground 槽”，没有覆盖分块公平性、foreground 压力期 background 限流或 active background 晋升 current。
- 现有 decode detach 测试只覆盖 `retainDepth: 0` 的静态重播，没有覆盖保留 successor 后离开/回到上传窗口的 cursor 连续性。

## 所有权清单

| 状态 / 资源 / 命令 | 当前所有者 | 正确所有者 | 结论 |
|---|---|---|---|
| persistent artifact 读取并发与公平性 | `downloads.ArtifactCacheReadScheduler` | `downloads` | 保持；改为分块 lease，不下沉到 Reader/App |
| 当前 artifact read priority | `pipeline_runtime` demand plan，经 callback 注入 transport | `pipeline_runtime` | 保持权威来源；scheduler 每个分块重新读取 |
| encoded source / session-copy | `downloads` + `sessions.DownloadSession` | 原所有者 | 不新增 Reader 私有缓存或旁路 |
| decode cursor、holder 与 detach | `sessions.DecodeSession` | `sessions` | 修复 retained frame 与 cursor 的连续性 |
| current/transition demand | `pipeline` + `pipeline_runtime` | 原所有者 | 不缩小 7/3、2/1 或 upload current/transition |
| 页面播放与呈现 | `sessions.UploadSession` + `texture_bridge` | 原所有者 | 不建立竞争 playback 状态 |

## 被否决方案清单

1. **缩小下载 7/3、页面预解码 2/1 或 lane 5/3/2**：仅隐藏拥堵，破坏既定策略；否决。
2. **关闭 background artifact 预取**：会退化正常热切页能力；否决。
3. **Reader/App 建立私有 encoded-byte LRU 或保持第二套页面 source**：违反缓存与 session 所有权；否决。
4. **角色晋升时取消并重开 active artifact stream**：丢弃已读进度并制造重复 I/O；否决。
5. **detach 后无条件重建 decode cursor**：对仍保留 successor 的动画会重新产出 frame 0，造成重复首帧和播放停滞；已由 Trace 证明退化，禁止换名恢复。
6. **仅增加并发槽**：设备已显示并发达到 5 后仍拥堵，增加并发会放大 I/O、ingress 和 decode 压力；否决。

## Trace 证据

- `framePipelineTiming`：330 条；end-to-end p95 约 1.40 秒，最大约 24.43 秒。
- persistent artifact stream：36 条；最大并发 5；stream p95 约 2.54 秒；first-chunk p95 约 1.45 秒。
- 页面 17 在成为 current 后先呈现 retained frame 0；其 playback due 后，UploadSession 再次上传 `frame 0`，随后才解出 frame 1/2。该重复首帧来自 detach 后 `_restartAfterDetach` 在 holder 非空时仍被置为 true。
- 页面已经流畅后切页，相关 artifact 全量复制和 encoded-source 填充已完成，因此后续 current 可直接使用热 source/cursor，符合用户观察。

## 修复目标

1. persistent artifact scheduler 以 chunk 为公平调度量；每个 chunk 读取前重新读取权威 priority。
2. foreground 有 active 或 pending 压力时，background 同时最多使用一个 chunk 槽；foreground 压力消失后 background 可恢复使用全部容量。
3. active background 晋升 current 不取消、不重开同一 stream，只在下一 chunk 重新分类。
4. DecodeSession detach 若保留 frame，则保留当前 cursor 连续性；只有 holder 为空时才标记下一次 demand 重建 cursor。
5. 增加 owner package 回归和静态门禁；设备效果保持 Unverified，等待 dev.104 Trace。
