# ADR 0091：Reader 重进清理与渐进 artifact handoff

**状态：Provisional**

## 问题

dev.106 设备 Trace 显示两个独立问题：

1. 旧 Reader 开始 dispose 后仍持续约十秒，期间新 Reader 已建立并完成大部分生命周期。`PromotedArtifactCacheHandoff` 在确认相同 identity 与长度的持久副本已存在之前，仍会读取临时 DownloadSession 的完整 promoted artifact。
2. current/transition 的 encoded bytes 已在内存中，但作为单个数 MiB 至十余 MiB response chunk 注入。`sourceReady` 必须等待整块 native ingress 与临时 artifact 写入完成，首个可解码前缀不能提前生效。

## 决策

1. `downloads` 提供可选的 `ArtifactCachePresenceStore`。handoff 在读取临时 artifact 之前按 `DownloadId + expectedLength` 探测持久副本；命中时记录 `skip-existing` 并直接完成。
2. current/transition 继续使用 composition encoded-byte cache、foreground lease-through-stream 与 startup pressure，但 response 改为 1 MiB 渐进分段；每段之间让出事件循环，使 source-ready、decode 和 current presentation 能在完整 body 消费前推进。
3. background 继续使用既有 1 MiB quantum 与动态 priority，不改变下载 7/3、预解码 2/1 或 lane 5/3/2。
4. Reader dispose 先 detach handoff listener，再关闭 coordinator；只等待真正需要写入持久层的 commit。dispose Trace 分开记录 coordinator、handoff、media、downloads 与 workspace 阶段。
5. 快速重进不通过阻塞导航等待旧 Reader，也不清空热缓存；目标是让旧 Reader 没有无意义的完整文件工作。

## 所有权

- `downloads`：持久副本 presence、handoff、encoded-byte delivery。
- `pipeline_runtime`：Reader 生命周期、pressure 投影与阶段 Trace。
- `sessions`、Reader Presentation、native decode 与 Android texture 所有权不变。

## 拒绝方案

- 等待旧 Reader 完全 dispose 后才允许导航：把后台问题转化为可见阻塞。
- 提高缓存上限或全章常驻内存：不能消除重复 handoff，也会扩大内存耦合。
- 直接复用旧 DownloadSession：会跨 Reader 共享可变生命周期。
- 恢复单个 whole-body chunk：会再次阻塞 source-ready。

## 解除 Provisional 条件

设备 Trace 证明：旧 Reader 的 `handoffDrainMicros` 不再出现秒级长尾；相同持久 artifact 记录 `skip-existing`；current 使用 `startup-segmented`；首个 1 MiB 前缀后即可进入 source-ready/decode；快速重进期间旧 Reader 不再与新 Reader 长时间重叠。
