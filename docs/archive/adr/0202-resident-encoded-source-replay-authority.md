# ADR 0202：resident encoded-source replay authority

- Status: Accepted
- Version: 0.31.0-dev.221

## 问题

`DownloadJob`对durable immutable source采用resident ingress：正文直接fan-out到Reader projection，不再复制一份到session artifact。因此physical `DownloadSession.committedLength`可以来自resident length，而`session.artifact.committedLength`仍为0。dev.219 late join却统一从session artifact replay，导致后加入Reader获得sealed空source，同时physical owner因session已promoted而不会重新下载。

## 决策

1. `DownloadSession`只拥有physical transfer/residency boundary，不推断resident正文的持久化位置。
2. synchronized late projection接受抽象`DownloadIngressReplayChunks`。普通partial/hot artifact仍由session artifact提供；resident immutable session必须由外部replay authority提供prefix。
3. `DownloadIngressProjectionRegistry`保持Reader-local，并注入`ResidentIngressReplaySource`。
4. `PipelineReaderSession`的resident replay优先读取唯一composition `ArtifactCacheManager`；`file/content/asset`等可重开immutable source可由该Reader source transport提供同一严格有界prefix。两条路径都继续服从composition `ArtifactCacheReadScheduler`。
5. 不建立第二套cache，不把cache manager依赖下沉到`sessions`，不改变physical download/retry/priority owner。

## 非目标

本轮不推进verified TransferKey，不调整NetLane、水位/retry，也不以origin fallback掩盖remote durable cache一致性错误。
