# ADR 0099：空 Artifact 自愈与纵向静态 Host 保活

**状态：Provisional**

> dev.116 修订：空 Artifact 自愈仍保留；“可选 backend invalidation”与“仅按 animatedHint 保活纵向 host”由 ADR 0100 取代。backend 失效成为必需存储原语，纵向轻量 host 不再依赖解码前 hint。

## 问题

dev.113 的 durable cache direct-ingress 不写 Reader 临时 artifact，但旧 `PromotedArtifactCacheHandoff` 在 session promoted 后仍读取该临时 artifact。其正文为空，随后被写回中央 memory tier 与 persistent backend。后续 Reader 稳定命中 0 字节条目，在图片签名识别阶段抛出 `FormatException`；这发生在 native/WebP decode 之前，不等同于此前的 cursor decode failure。

纵向静态 Reader 虽扩大了 Sliver cache extent，页面 host 仍未申请 keep-alive。邻近 previous/last 页仍可能在轻微反向滚动前 dispose，重新挂载时顶部出现短暂 loading 条带。

## 决策

1. cache-resident promoted session 在 handoff 中直接记录 `skip-cache-resident`，不得读取或回写不存在正文的临时 artifact；任意 0 字节 handoff 记录为 `skip-empty`。
2. `ArtifactCacheManager` 禁止保存空 bytes；读取时若发现空 entry、materialize 为空或长度漂移，清除 L1，并通过可选 backend invalidation 能力清除 L2 后返回 origin fallback。
3. Memory/Persistent chapter backend 只实现存储原语和腐败条目删除。Persistent backend 对 index bytes<=0、文件为空、文件缺失或长度不一致执行 index+file 自愈清理。
4. `DownloadJob` 拒绝 `Content-Length=0` 和 unknown-length 但最终无正文的响应；durable cached ingress 也不得以 0 长度封缄。
5. 纵向静态页面 current 前后 4 页保留轻量 Widget host。decoded frame、texture、cache body 与 session 不由 Widget 保活，仍受 Pipeline demand 和 FrameBudget 控制。

## 所有权

- tier、失效和 fallback：`downloads/ArtifactCacheManager`。
- durable backend 清理：`downloads` chapter backend。
- response admission、ingress 和 promoted 状态：`sessions`。
-纵向轻量 host：`reader`；重资源所有权不变。

## 拒绝方案

- 仅捕获并隐藏 `FormatException`：毒化缓存仍会永久命中。
- 让 decoder 对空 bytes 重试或增加 chunk：空正文不可能通过解码恢复。
- 启动时清空整个缓存：会破坏正常持久资源且不能修复生成空条目的生命周期错误。
- 让 Widget 保留 decoded image/texture：会建立第二套缓存和资源生命周期。

## 解除 Provisional 条件

设备 Trace 证明：`emptyArtifactEventCount=0`、不存在 `stored bytes=0`；历史毒化条目首次命中后被失效并自动回源；相关页面成功得到首帧；纵向 previous/last 邻域不再因 host dispose 出现顶部短暂 loading。
