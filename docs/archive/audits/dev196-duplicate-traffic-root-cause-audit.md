# dev.196：partial 重启重复流量根因审计

## 基线

唯一代码基线是 `zic_v0.31.0-dev.195_dev192-restart-monotonic-playable-partial.zip`。dev.193/dev.194 仍是已否决实验线；本轮不恢复其 DecodeSession 或多分支 catch-up 实现。

## 真机证据

`zic-debug-trace-2026-08-10T03-12-10.jsonl` 中有 36 条 origin `sourceRead` body，累计 182,701,516 bytes。按每个 `resumeRestarted strategy=full-body-prefix-catchup` 的旧 `committedLength` 与随后同 identity 的实际 origin body 取 `min(bodyBytes, oldCommittedLength)`，12 次 fallback 至少有 30,204,901 bytes 只是在重新读取已经存在的 authoritative partial，占观测 origin body 约 16.5%。

代表性 identity `-7b2d...`：第一次已得到 10,136,780 bytes；下一次 full-body catch-up 从0读 3,022,200 bytes 后被取消，全部为零新增收益；后续再次从0读取完整 14,585,586 bytes。最终文件 14.59 MB，但 origin 合计 27,744,566 bytes。

另一个 identity `-4776...` 最终 16,419,756 bytes，origin 分三次读取 2,135,980 + 4,984,440 + 16,419,756 = 23,540,176 bytes。

## 根因定位

- `normalizeSourceResourceRequest()` 会把非空 `ByteRange` 写为 `Range: bytes=...`，206/Content-Range解析本身存在；但dev.195 `DownloadJob._open()` 只有validators可resume时才真正传Range，validatorless path因此主动full open。
- production rhttp direct transport还存在第二个Range缺口：它对所有200/206都调用完整媒体prefix检查。`Content-Range.start > 0`的中段没有图片magic header，会被误判为`sourceMediaProtocolMismatch`并转runtime fallback；同文件中的Dart HttpClient direct path已经对中段绕过该检查。dev.196让rhttp与该既有语义对齐。
- 频繁 NetLane cancellation 会放大 full-prefix catch-up 的浪费，但不是“为什么每次都从0”的根因。先修 continuity transport strategy，再决定是否需要 restart-cost-aware scheduling。

## dev.196 收口

- 已知 totalLength 的 validatorless partial 先请求最多64KiB尾部 open-ended Range；
- 仅精确206/start/totalLength + byte-exact overlap通过才续写；
- Range返回200时复用同一完整response进入现有full-prefix CRC fallback；
- strong-validator请求被200拒绝也复用同一body；
- fallback/probe记录 `duplicatePrefixBytes`，取消前已验证的重复字节也直接进入resume trace；
- rhttp合法206中段跳过完整图片magic-prefix检查，但raw cadence、cancel与read diagnostics不变；
- playable partial、Ingress、epoch 与 dev.195 authority规则不变；DecodeSession、NetLane与Reader/Pipeline不修改。

## 待真机验证

1. 对当前 E-Hentai/H@H page body，确认 validatorless resume 是否返回206；若是，`duplicatePrefixBytes`应通常≤65536且不再出现数MB full-prefix重复。
2. 若服务器返回200，确认同一 attempt 记录 `fullBodyResponseReused=true`，没有随后第二次 full open。
3. 统计整段 `sum(duplicatePrefixBytes)` 与 origin body 比例；只有真正不支持 Range 的 CDN 仍应出现大额 full-prefix fallback。
4. 在重复流量收敛后再评估 active stream bandwidth/preemption，不把本轮结果解释为 bandwidth scheduler 结论。
