# ADR 0176：可播放 partial 单调性与 full-body prefix catch-up

## 状态

Accepted。直接建立在 dev.192 / ADR 0175 上。dev.193 与 dev.194 的 overlap/catch-up 实验线被否决，不属于本 ADR 的代码基线或实现来源。

## 问题

dev.192 的 `DownloadJob` 把“本次网络请求无法安全 Range resume”与“已有 partial artifact 已失效”合并为同一状态：无 validator、durable response 或 `requireResumeResponse` 拒绝时会 `session.reset()`。`DownloadSession.restore()` 又会在每次新的 DownloadJob run 开头无条件重建 Ingress。因此 transport attempt 重启可能删除/缩短已提交文件，或在字节未删除时仍重建正在播放的 encoded source。

后续 dev.193/dev.194 试图以 validatorless overlap resume 和多分支 catch-up 修补该路径，但把 transport 连续性验证、artifact authority 与播放状态继续缠绕；设备 trace 出现多个并行 `full-body-overlap-catchup` 和 terminal resume 分支，修改面扩大且回归累积。因此这条实验线整体丢弃，从 dev.192 重新定义底层不变量。

## 决策

1. 对稳定 `DownloadId`，已提交并成为 playback authority 的 partial prefix 单调不减。transport restart、missing validators、Range rejection、retry 或 source-open fallback都不能删除、缩短、换 epoch或重建仍与 artifact 一致的 Ingress。
2. strong validator + 合法 206 Range 继续使用原有 Range resume。
3. 无法证明 Range resume 时，`DownloadJob`直接从 byte 0 打开当前完整 response，不先尝试 validatorless Range。旧 artifact 与 Ingress 原地保留。
4. full-body catch-up 在 `[0, oldCommittedLength)` 期间只消费网络字节并计算 CRC32；不获得新的 playback authority，不写 artifact，不推进 Ingress。现有 partial 的 CRC32 来自 `Artifact.restore()` 的权威 rehash。
5. 只有完整收到旧 boundary 且收到前缀 CRC32 与现有 partial checksum 相同，才允许把 boundary 之后的 response bytes交给既有唯一 writer，并从 `oldCommittedLength` 单调 append。response total length若小于旧 partial、prefix mismatch、取消或提前 EOF都只终止当前 network attempt，旧 partial不变。
6. `DownloadSession.restore()` 若当前 Ingress 的 epoch、length、content kind、sealed/failure状态已经与 authoritative artifact一致，只恢复网络 metadata，不 rebuild native encoded source。
7. resume metadata 缺失、格式损坏或 validator 信息不可用只表示网络知识退化，不证明 media bytes损坏。只有 metadata 明确声明另一个 DownloadId/owner、artifact 自身完整性失败或显式 evict/clear 才允许减少 committed playback bytes。
8. 本轮不修改 `DecodeSession`、partial-loop、Reader/Pipeline policy、NetLane、network concurrency 或带宽分配。若在上述不变量成立后仍有动画停播，必须以新的真机证据单独审计播放 producer。

## 后果

- CDN 即使忽略 Range，网络仍可能从0重新传输旧前缀，但播放器继续消费旧 partial，`sourceLength`和epoch不因网络 attempt倒退。
- 完整前缀 CRC 校验比小 overlap 更保守，代价是在 fallback catch-up 中对重复网络前缀做一次 Dart CRC32；实现按网络 chunk 处理并在 chunk 间 yield，且该成本只出现在不能证明 Range resume 的 fallback，不进入正常下载热路径。
- 没有第二份 playback artifact、shadow writer、Reader retry owner或新的 bandwidth scheduler；Artifact/Ingress仍是唯一 playback authority。
