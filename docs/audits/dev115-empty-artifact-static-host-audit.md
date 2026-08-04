# dev.115 空 Artifact 与纵向 Host 生命周期审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.114_vertical-visible-static-memory-preload.zip`。
- 格式错误 Trace：`zic-debug-trace-2026-08-04T03-42-26.jsonl`。
- 纵向静态 Trace：`zic-debug-trace-2026-08-04T03-44-37.jsonl`。

## 证据

格式错误样本包含 45 个 0 字节 artifact/source 事件，其中 28 个为 handoff `stored bytes=0`。0 字节 memory hit 随后被 promoted，并作为 presentation bytes 使用。

纵向样本包含 41 个 0 字节事件、30 个空 handoff 回写；8 个 page host dispose 均发生在首帧前。page 15 在 current 移到 16 后仍位于邻近区域，却被 dispose，反向滚动时需要重新挂载。

## 根因

- direct durable ingress 与旧 handoff 对“promoted 必有本地 artifact 正文”的假设冲突。
- cache manager/backend 未禁止 0 字节 entry，也没有逐层失效能力。
-纵向 Sliver cache extent 不能替代 child keep-alive。

## 修改

- cache-resident handoff skip；空 store/read/incoming response admission；L1/L2 自愈失效。
- Persistent index/file corruption cleanup。
-纵向静态 current±4 轻量 host keep-alive。
- analyzer 空 artifact 统计与 dev.115 ownership gate。

## 未验证

当前环境没有 Flutter/Android 工具链或设备，无法声明历史毒化缓存已在设备自动恢复，或顶部重载条带已经消失。
