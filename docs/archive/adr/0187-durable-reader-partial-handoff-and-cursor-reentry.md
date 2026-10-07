# ADR 0187：Reader durable partial handoff 与 decode cursor 重入

## 状态

Superseded by ADR 0188；cursor-reentry correctness 保留，route-retain checkpoint 与 ArtifactCache partial wiring 被替换。

## 背景

12:24 真机 trace 同时暴露两个长期存在而未被 promoted cache 覆盖的 partial 生命周期缺口。

第一，新 Reader session 创建后 current page 的 DownloadSession 以 `committedLength=0` 启动并从 origin 获取，而相邻已完成页面可以直接从 persistent artifact 命中。现有短期 Reader session retention 只能在同一 session TTL 内保留 ephemeral partial；真正 dispose 时 workspace 被删除，未 promoted partial 没有 durable handoff。

第二，Animated WebP 页面重新进入可见窗口时已有约3.1MiB partial。旧 cursor 已经解到 frame25 并留下更高的 next-frame prefix requirement；holder 为空后 session 已请求从 frame0重建 cursor，但旧实现先检查 stale requirement、后处理 cursor restart，导致首帧必须等待网络 full-body catch-up超过旧 frame25 boundary。

## 决策

1. 未 promoted partial 与 promoted immutable cache 必须类型分离。新增可选 `PartialDownloadStore`，不得把 partial 伪装成 cache hit/promotion。
2. durable partial backend 复用现有长期 `PersistentChapterDownloadService` 的 DownloadRegistry/Artifact/CacheIndex；不建立第二套 Reader/App partial 文件树。
3. Reader route retain 时异步 checkpoint 当前稳定 committed prefix，固定 `endExclusive`，不阻塞 route 返回；真正 dispose 前等待已发 checkpoint并做最终 drain，再删除 ephemeral workspace。
4. 下一 Reader session 在网络打开前按精确 DownloadId 恢复 partial、validators 与 totalLength 到自己的 authoritative DownloadSession/Ingress。
5. DecodeSession 若 holder 已空且 `_restartCursorWhenHolderEmpty` 为真，必须在 nonsealed prefix requirement gate 之前释放旧 cursor/清除旧 continuation state，使当前 authoritative partial 可以从 frame0重建。
6. 网络 Range/admission/restart-cost、Reader 7/3、decode 2/1、network=5 与 promoted cache semantics 不因此改变。
7. rhttp 的当前统一边界只覆盖最终无状态 media host replay。Venera resolver `Network.*`仍属于 plugin-host source-owned HttpURLConnection client；完整 resolver→rhttp 收口单独治理，不能与本 ADR 的 partial correctness 混改。

## 风险边界

checkpoint 是正常 lifecycle 的 best-effort durable handoff；进程被强杀且异步 checkpoint尚未完成时，不宣称最后一个未落盘 prefix 绝对持久。若长期 ChapterDownloads 同 DownloadId 正在被另一个 writer占用，Reader checkpoint可失败并报告，但不得阻塞 route 或创建第二 writer。
