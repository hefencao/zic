# ADR 0304：Venera 图片语义恢复与 source-client fallback 分离

## 状态

Accepted

## 触发证据

18:44 真机 trace 中，Reader page25 已不再被 generic 6 秒 open watchdog 杀死；physical attempt 约 11 秒后以 `Failure(source): Venera resource returned non-image bytes` 结束。代码复审发现 direct/rhttp 的“2xx 但正文不是图片”和 redirect/Cookie/interceptor/session-state 无法由 host 无状态重放，都只使用 `sourceMediaProtocolMismatch`。上层因此把前者直接送进 full-runtime `loadResource`，先重复请求原 URL，再由 runtime 内部调用 `onLoadFailed`，让 semantic retry 与 client fallback 混成两个恢复 owner。

## 决策

1. `sourceMediaProtocolMismatch` 只保留兼容性的总类诊断，不再作为 runtime fallback 的充分条件。
2. host direct/rhttp 在完整/首段 2xx body 被图片 magic-prefix 拒绝时标记 `sourceMediaSemanticRejected=true`。该 bytes 不进入 Pipeline/native token，Venera runtime HTTP cache 中对应 URL 同时失效。
3. `SourceResourceTransport` 对 initial semantic rejection 只调用 source `retryResource/onLoadFailed` 一次，执行返回的 replacement request plan；不得先 full-runtime 重放原 locator。
4. replacement 再发生 semantic rejection时立即转为 non-retryable `ErrorCode.source`；不得继续 provider RetryPolicy、不得调用第二次 source semantic retry。
5. 只有 `sourceClientStateRequired=true` 才允许直接交还 source-owned runtime client，以保留 redirect/Cookie/interceptor/session-state。
6. 若 external `retryResource` 已生成 replacement，而该 replacement 随后因 transform/client-state 必须 full-runtime 执行，Venera retained config 必须携带 operation-local semantic-retry-consumed fence；runtime 只执行当前 replacement，不能再次调用其 `onLoadFailed`。
7. fence 不永久消耗 durable locator。后续独立用户/physical retry再次请求 semantic recovery 时，runtime从自描述 `venera-resource:` identity fresh resolve原 image config，再获得新的一次 source-owned recovery budget。

## 非目标

不增加 E-Hentai 特判，不改变 provider retry 次数，不扩大 Venera JS 并发，不把 `Network.fetchBinary` 收窄为图片 API，也不通过增加 timeout 掩盖 source semantic failure。

## 验证

- downloads 回归覆盖 original non-image → one replacement success、replacement non-image → source terminal、client-state → runtime fallback。
- Venera bootstrap contract覆盖 external `retryResource` 已消费后 full `loadResource` 不得第二次调用 replacement `onLoadFailed`，以及后续独立 retry 可 fresh resolve。
- Android Kotlin compile验证 private image-binary bridge与bootstrap字符串实际可编译；Node 不可用时不得把 bootstrap行为用例伪报为已执行。
