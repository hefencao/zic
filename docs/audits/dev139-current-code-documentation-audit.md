# dev.139 当前代码与文档一致性审计

## 唯一基线

`zic_v0.31.0-dev.138_vibevenera-transition-first-frame.zip`

## 审计方法

按文档规定顺序读取稳定文档，然后直接核对 production source、owner tests 和 Android bridge。历史 audit/ADR只用于识别取代关系，不作为当前实现事实来源。

## 发现的过时内容

1. Architecture/Spec 只写“前 2/后 1 预解码”，没有区分角色窗口和 7/5/3/2 holder 最大水位。
2. 生命周期仍写 Reader 退出即逆序销毁整套 session，遗漏 1 项/2 分钟的章节资源 retention。
3. WebP 文档写 current 两个 successor、transition 一个，与 `HeuristicPolicy` 和 staged refill 不一致。
4. 网络 256 KiB 被写成 transport 分块；当前 DownloadJob 实际先 16 KiB、后 64 KiB，256 KiB 是 remote prefix hint。
5. Android texture 文档遗漏单 blit lane、默认 platform channel、普通 main post和 used texture 不跨 Reader 复用。
6. 缓存文档没有记录 ArtifactCacheManager 10 项/256 MiB、verified alias 和 response/artifact 双平面。
7. ADR 0113–0121 多个状态使用“部分取代/带版本 Accepted”等非规范写法，且仍把已删除 affinity/FlowGate 写成近端当前入口。
8. README 包职责仍把 DownloadSession 状态归到 downloads，未反映 sessions/pipeline_runtime 当前所有权。

## 源码事实

- `ReaderPipelineProfile.stable`：encoded +7/-3、decode role +2/-1、network/local/remote/decode/upload = 5/2/5/3/2。
- `StagedDecodeRefillPolicy`：transition `t>0`；随后 c/n/m/p 最大 7/5/3/2。
- `PipelineReaderSessionFactory`：共享 NetLane，current reserved slot 1、threshold 1000、preemption 40；retention 1 项、2 分钟。
- `DownloadJob`：首批 16 KiB，之后 64 KiB。
- `WebpDecodePrefixHints`：local 1 MiB、remote 256 KiB。
- `ArtifactCacheManager`：memory 10 项/256 MiB、alias 8192。
- `TextureBridgePlugin`：一个 blit lane、默认 MethodChannel、`mainHandler.post`。
- `UploadSession`：holder-driven、缺 successor 保留当前 output，不生产 startup buffering。

## 修改范围

更新 README、AGENTS、Architecture、Spec、Plan、Status、Handoff、Documentation Policy和近端 ADR 状态；新增 ADR 0122 和文档一致性门禁。没有修改 Reader/Pipeline/native 产品行为。

## 拒绝方案

- 不把历史 Trace 数字复制进 Architecture/Spec。
- 不删除历史 ADR/audit；通过 Superseded 和综合 ADR保留决策演进。
- 不因为文档更新改变 7/3、7/5/3/2、lane、cache 或 retention 常量。
