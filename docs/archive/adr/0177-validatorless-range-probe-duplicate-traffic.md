# ADR 0177：validatorless Range continuity probe 与重复流量边界

## 状态

Accepted。建立在 dev.195 / ADR 0176 的 playable-partial 单调性上，不恢复 dev.193/dev.194 的播放或多分支续传状态机。

## 问题

dev.195 为避免无 validator 的 partial 被 reset，统一从 byte 0 重新读取完整响应并对 `[0, oldCommittedLength)` 做 CRC32 catch-up。03:12 真机 trace 中 36 条 origin body 共约 182.70 MB，12 次 `full-body-prefix-catchup` 至少重新读取 30.20 MB 已有 partial（约 16.5%）；其中一个 14.59 MB 最终文件实际读取 27.74 MB。catch-up 在追平旧 boundary 前被取消时，本轮已读取字节完全不能增加 playable partial。

源码审计确认有两个连续根因：首先 dev.195 `DownloadJob._open()` 在 validators 为空时主动不传 `ByteRange`；其次 production rhttp direct transport 即使收到合法206中段，也会无条件把该中段的前16字节当完整图片头做magic-prefix校验，中段自然不含`RIFF/WEBP`等头部，从而误触发`sourceMediaProtocolMismatch`/runtime fallback。纯Dart host path已在`Content-Range.start > 0`时跳过该校验，rhttp此前未对齐。

## 决策

1. dev.195 的 playback authority 不变量保持：网络 attempt 无权 reset、缩短、换 epoch 或重建仍与 artifact 一致的 playable partial。
2. strong validator resume 保持原策略：从 `oldCommittedLength` 请求 Range 并使用 validator 校验。
3. 对 `oldCommittedLength > 0`、validators 为空且已知旧 `totalLength` 的 page body，`DownloadJob` 先发一个无 `If-Range` 的 open-ended Range probe，起点为 `max(0, oldCommittedLength - 64 KiB)`。
4. validatorless probe 只有同时满足以下条件才获得 continuity：HTTP 206、`rangeStart` 精确等于 probe 起点、返回 `totalLength` 与旧记录完全一致、probe 到旧 boundary 的 overlap 与现有 artifact 逐字节一致。验证完成前不写 artifact/Ingress。
5. continuity 成立后，probe response 在旧 boundary 之后的 remainder 与后续 body 直接交给既有唯一 writer，从 `oldCommittedLength` 单调 append。该路径重复网络字节最多为 64 KiB；partial 小于 64 KiB 时验证整个已有 prefix。
6. 若服务器忽略 Range 并以 HTTP 200 / `rangeStart=0` 返回完整 body，必须复用**同一个 response**进入 ADR 0176 的完整前缀 CRC32 catch-up，禁止仅为了 fallback 再打开第二条 full response。strong-validator Range 被 200 拒绝时同样复用该 response。
7. probe 返回其它不可接受的 response 时可 discard 后回到完整 body fallback；旧 playable partial 始终保留。未知旧 `totalLength` 时不做 validatorless Range probe，直接沿 ADR 0176 的 full-prefix proof。
8. `resumeProbeStart/resumeProbeBytes/resumeProbeStatusCode/resumeProbeAccepted/duplicatePrefixBytes/fullBodyResponseReused` 只属于 trace 观测。NetLane、Reader、retry、cache 与 transport framing 不得依据这些字段决策。
9. rhttp direct transport对`Content-Range.start > 0`的合法partial response不得做完整媒体magic-prefix校验；仍保持raw body cadence、同一TaskControl cancellation和read diagnostics。rangeStart=0的完整/首段response继续执行媒体头验证。
10. 本轮不修改 DownloadSession authority、DecodeSession、Reader/Pipeline、NetLane、network=5、priority 或 bandwidth policy。

## 安全边界

validatorless Range 不等价于 HTTP validator。这里接受的是 page-media 模型下的有界 continuity proof：稳定 DownloadId + 已知且不变的总长度 + 精确 Range 语义 + 最多 64 KiB 尾部逐字节一致。若来源可能在同一 DownloadId、相同长度且相同 overlap 下替换更早内容，该证明不足；这种来源应提供 validator 或让 probe 条件失败后回到完整前缀验证。不得把该策略推广到任意可变文档或 metadata response。

## 后果

- 支持 Range 的 validatorless CDN 不再为每次 restart 重传整个旧 partial，典型重复字节从数 MB/十数 MB 降至最多 64 KiB。
- 忽略 Range 的 CDN 不会因 probe 额外产生第二次 full-body open；重复成本与 dev.195 fallback 相同，但 trace 会直接报告 `duplicatePrefixBytes`。
- 调度经济性问题与 transport continuity 分离：只有在确认目标 CDN 真正不支持 Range、full-prefix fallback 仍频繁被抢占后，才重新评估 NetLane 的 restart-cost-aware preemption；本 ADR 不提前增加该策略。
