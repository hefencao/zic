# dev.170 Mihon WNACG 媒体与重试根因审计

## 证据

输入：`zic-debug-trace-2026-08-08T11-55-06.jsonl`。

- 共 8994 条 Trace 记录。
- WNACG source `mihon:6551136894818591762` 的 browse成功；details刷新成功并得到 1 章；chapter catalog刷新成功，因此插件激活、目录与详情元数据链不是主故障。
- source-browser 对 WNACG记录 30 个 `cover-load-start`、0 个 `cover-source-ready`、30 个 `cover-source-failed`、0 个 decode failure，说明封面在 presentation decode之前就失败。
- Reader共出现 2788 个 `downloadStarted`、2684 个 `taskFailed`；其中 2654 个完全相同：`UnknownServiceException: CLEARTEXT communication to img5.wnimg1.ru not permitted by network security policy`。
- 只有 6 个主要 page DownloadId，却各自被重新启动约 446–516 次；这是失败重提热循环，不是正常分页或新 demand。

## 根因 A：Android宿主缺少 extension media cleartext capability

WNACG source实际返回 HTTP图片 host。App manifest没有 `usesCleartextTraffic` 或 Network Security Configuration，因此 source-owned OkHttp在真正网络请求前被平台策略拒绝。封面与正文共享同一个进程级能力缺口。

否决方案：

- `wnimg1.ru` 域名白名单：插件媒体 host可变化，且会使 App接管 source知识。
- HTTP→HTTPS改写：改变插件权威 request，目标站未必提供等价 HTTPS。
- cover/page分别加 fallback：复制 transport owner，不能解决进程网络能力。

## 根因 B：Download terminal failure没有所有权

`LiveCoordinator._runDownload`已有 RetryPolicy，但旧代码同时存在两条额外重提路径：

1. `_watchSource()` 在 `snapshot.failure != null` 后再次 `_ensureDownloadTask()`；
2. `_runDownload()` 的 `finally` 对仍有 demand且未 promoted/disposed的 session无条件再次 `_ensureDownloadTask()`。

`ErrorCode.source`不进入 `_scheduleDownloadRetry()`，又没有 terminal latch，因此确定性 source错误立即被 `finally` 重新提交，形成数千次热循环。network recovery达到上限也存在同类重新提交风险。

## dev.170 收口

- App绑定统一 `network_security_config.xml`，base cleartext capability开启；没有 WNACG域名条目。
- runtime adapter保留 `retryable`，将 transient普通错误映射为 `ErrorCode.network`。
- Mihon `UnknownServiceException`不再标记 retryable。
- `LiveCoordinator`新增 `_downloadTerminalFailures`；source listener删除下载重提权；`finally`尊重 terminal状态；有界 recovery调度返回显式 bool，耗尽后terminal。
- source-card cover failure Trace增加 `errorCode/errorMessage`。

## 未验证

当前环境没有 Flutter/Dart/完整 Android build工具链，因此必须在用户设备上重新安装 dev.170并验证 WNACG真实封面与正文。Network Security XML/Manifest、静态 owner gate与可用 Kotlin/仓库门禁可以本地验证，但不能替代真机 OkHttp行为。
