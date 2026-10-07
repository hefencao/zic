# ADR 0122：当前 Reader Pipeline 权威与生命周期收口

> dev.247：ADR 0227仅细化昂贵动画WebP的network-admission子集；本ADR的previous3/next7逻辑RoleWindow与decode/holder所有权继续有效。


**状态：Accepted**

## 背景

Reader Pipeline 在多轮性能修复中先后出现 startup-buffer、跨 Reader retained output、CPU affinity、hot-byte 重灌和 holder-depth network gate。部分决策后来被删除或替换，但 Architecture、Spec 和近端 ADR 状态没有同步，容易让后续实现再次恢复已删除路径。

本 ADR 只收口 production source 中已经存在的稳定权威，不以单次 Trace 推断新机制。

## 当前决策

1. `pipeline` 只把 `ReaderObs` 转换为角色和 demand；`pipeline_runtime`/`sessions` 执行资源生命周期，Reader 不拥有资源算法。
2. encoded window 为前 7/后 3；深度 decode 角色为前 2/后 1；动态 holder 最大水位为 current/next/next2/previous = 7/5/3/2。
3. transition depth 为 0 时独立取得一帧，之后恢复 staged current/neighbor refill。不得恢复 current-only 或 startup-buffer eligibility gate。
4. `NetLane` 是唯一网络调度权威。current 使用高优先级保留槽、priority migration 和 preemption；holder/playback 状态不能控制其他页面 transport。
5. DownloadJob 首批约 16 KiB、后续约 64 KiB 合并小 transport chunk。local/remote WebP decode-prefix quantum 仍分别为 1 MiB/256 KiB，两者不得混写。
6. playback 由 holder 和 one-shot deadline 驱动；缺少 successor 时保留当前 output并等待 producer，不阻塞其他页面。
7. Android 使用默认 platform channel、单 blit lane和普通 main-thread post。used texture 不跨 Reader 复用；未使用 prewarm lease 可有界复用。
8. Reader 资源会话最多保留 1 个 idle chapter、TTL 2 分钟；保留 download/source/decode 资源，释放 Reader binding、projection、playback wake 和 used texture。
9. response cache 与 page artifact cache保持两个权威平面；ArtifactCacheManager 默认热字节 10 项/256 MiB，alias 只接受已验证关系。
10. CPU affinity、DownloadFlowGate、跨 Reader used-texture restore 和 startup-buffer 均不是当前架构。

## 所有权

- 角色窗口和 demand：`pipeline`。
- 网络、download/decode/upload session、holder、timer：`sessions`。
- 资源会话组合和 retention：`pipeline_runtime`。
- page artifact 与 alias：`downloads`。
- response cache：`resource_cache`/`catalog`。
- native cursor/frame ABI：`bridge`/`native/media_core`。
- Android texture：`texture_bridge`/`pipeline_native`。
- Reader：只负责 observation、命令和 presentation。

## 取代关系

- 本 ADR 取代 ADR 0113 作为 fresh texture/deadline wake 的当前架构入口；ADR 0113 的 affinity 部分已由 ADR 0117 否决。
- 本 ADR 取代 ADR 0115 作为 holder playback/hot-byte 的当前架构入口。
- 本 ADR 取代 ADR 0116 作为 single-blit 的当前架构入口；其 affinity 与重新灌入新 session 的路径已由 ADR 0117 删除。
- ADR 0117、0118、0119 和 0121 仍分别记录 retention、稳定 identity、catalog cache 和 transition 首帧的专项决策。
- ADR 0120 只保留首页分阶段发布和 transport 小块合并；其 FlowGate 已由 ADR 0121 删除。

## 后果

后续实现和文档必须首先检查这些唯一权威。优化 current 不得冻结 target；缓存命中不得创建第二套 session；Reader detach 不等于资源驱逐；used texture 不得作为后台恢复缓存。
