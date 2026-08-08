# ADR 0153：Mihon Cleartext Media 与下载失败重试所有权

Status: Accepted

## Context

`zic-debug-trace-2026-08-08T11-55-06.jsonl` 中，WNACG 的 browse、details 与 chapter catalog均成功，但 source-card cover 30 次加载全部在 source阶段失败；Reader页面实际解析到 `http://img5.wnimg1.ru/...` 后，由 Android/OkHttp 在请求发出前以 `UnknownServiceException: CLEARTEXT communication ... not permitted by network security policy` 拒绝。同一确定性失败又被 `LiveCoordinator` 重复提交数千次。

ZIC 是 Mihon extension host，media host由插件/source动态决定。按 WNACG域名做白名单或把 HTTP改成 HTTPS都会让 App越权成为 source request owner，并会在下一插件再次失败。

## Decision

1. Android App以统一 Network Security Configuration提供 cleartext transport capability；source/request plan仍决定准确 URL、method、headers、body与 client。配置不得包含具体 WNACG/wnimg域名。
2. external runtime error的 `retryable`语义必须跨 bridge保留：verification保持专用错误；retryable普通失败映射为 domain `ErrorCode.network`，其余为 `ErrorCode.source`。
3. `UnknownServiceException`属于当前 transport capability/policy不满足，不视为 transient network failure。
4. Reader page download retry只有 `LiveCoordinator` 一个 owner。`_runDownload`负责 RetryPolicy与有界 recovery；source snapshot listener只能唤醒 decode，不能重新提交下载。
5. non-retryable/source失败与 network recovery耗尽在当前 demand内记录 terminal failure。只有新/变化 demand或真实 source progress才能解除该 latch。
6. source-card trace在 source-load失败时记录 domain error code/message，以便区分 transport policy、source业务错误和 presentation decode错误。

## Consequences

- WNACG以及未来返回未知 HTTP media host的 Mihon extension无需新增 App域名特判。
- Android宿主允许明文 HTTP是兼容第三方 source的安全权衡；HTTPS source仍按其原 URL使用 HTTPS，ZIC不主动降级。
- 确定性失败不会再把 Reader网络 lane拖入无界热循环；真正 transient runtime network错误进入统一有界重试。
- 不新增第二套媒体 transport、封面 retry或 Reader fallback owner。
