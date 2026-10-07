# ADR 0308：Venera source semantic recovery chain

状态：Accepted；取代 ADR 0304 的第 3、4、6、7 项 one-shot recovery 决策。

## 触发证据

最新真机 trace 中某 Reader page 的 physical session 在 `committedLength=0`、`local-hydration-miss` 后首次进入 source network，最终以 `source image recovery returned non-media bytes` 结束；因此该失败与 partial、cache 或 decoder 无关。源码复审确认 ADR 0304 把 initial non-media 后的 source recovery 限制成一次 replacement，并在 replacement 再次返回 non-media 时直接转 terminal。

与 `~/projects/vibevenera/lib/network/images.dart` 对照后确认这不是 Venera 的原生语义：VibeVenera 由单一 image-download owner 持有 `retry=5`，每次当前 `ImageLoadingConfig` 失败后都可调用**当前 config** 的 `onLoadFailed` 生成下一 config；replacement 可以继续携带自己的 `onLoadFailed`。它不会因为已经产生过一次 replacement 就重新执行最初的 `onImageLoad`。

后续同一历史 E-Hentai page25 又形成了更强的 generation 差分：同进程内用户显式 fresh 已重新执行初始 `onImageLoad`，仍会重复 non-media；整进程重启后同一 locator 正常完成且章节继续推进。源码对应事实是 `VeneraHttpCacheStore` 由 plugin-driver host 跨 bridge/runtime replacement 保留，`cache-time: long` 可存活约 6 小时，而旧 `fresh:true` 只删除 retained resource config/resolution。若 `onImageLoad` 用 `Network.*` 解析最终图片地址，fresh hook 仍可能从旧 resolver cache 重建同一过期 request plan。

## 决策

1. `sourceMediaSemanticRejected` 与 `sourceClientStateRequired` 的 ADR 0304 分离继续有效；host/rhttp 的 image-media signature 校验继续严格拒绝 HTML/文本/其它 non-media bytes，绝不通过放宽 magic 校验修复恢复问题。
2. source semantic recovery 仍只有一个 owner。`SourceResourceTransport` 在一次 logical open 内最多消费 5 个 source-defined replacement config；replacement 再发生 semantic rejection时继续请求当前 source state 的下一 replacement，而不是交还 DownloadJob/provider RetryPolicy 新建另一层 semantic retry。
3. Venera runtime 为 retained image config 持有 `__zicSemanticRetryCount`，初始为 0，上限为 5。`retryResource` 只能调用当前 retained config 的 `onLoadFailed`，replacement 继承 `count+1` 并可携带新的 `onLoadFailed`；达到上限或当前 config 没有 callback 时返回 unavailable。
4. external streaming `retryResource` 与 full-runtime `loadResource` 必须共享同一 retained config 和同一 count。若 streaming 已消费 N 次，而 replacement 因 transform/client-state 进入 runtime，runtime 只能继续剩余 `5-N` 次；不得重新运行原始 `onImageLoad`，也不得另起一份 5 次预算。
5. source chain耗尽后仍转为 non-retryable `ErrorCode.source` / `sourceSemanticRetryExhausted`。这不改变 provider network retry 数量、NetLane admission、open/read watchdog、Reader 3/7、decode 2/1、partial persistence或cache authority。
6. 用户显式章节 Retry 是新的 download generation，但 historical failed task 可能跨进程只保留章节失败状态而丢失内存中的 terminal locator。此时本次 Retry 不得全章预刷新；它只可在首次重新确认一个 source-terminal locator 后 fresh 该 locator，并在同一用户命令内继续一次。已知 locator 仍在 run 前 fresh；一次 Retry 内同一 locator 只能 fresh 一次，未触达 locator 永不刷新。
7. 独立的新 image identity/runtime generation 可以从其正常 `onImageLoad` 建立新的初始 config；同一 retained logical resource 的失败链不得以“fresh resolve original config”逃逸当前预算。用户显式 fresh generation 重新执行 source hook 时，该 hook 内实际发起的 `Network.*` resolver 请求必须绕过并逐 URL 淘汰旧 host resolver cache，再按正常规则缓存新 origin response；此 fresh scope 不得清整个 source namespace、不得影响普通 browse/details cache、不得把当前 logical open 的 semantic retry budget 重置为新的一组 5 次。

## 验证

- downloads 行为回归必须覆盖 `original bad -> replacement bad -> replacement good`，证明第二 replacement 由同一次 source recovery owner消费。
- downloads 行为回归必须覆盖 5 个 replacement 全部 semantic reject，并断言第 6 次 `retryResource` 永不发生。
- Venera bootstrap contract必须证明 external retry 后 runtime fallback继续当前 replacement 的 `onLoadFailed`，同时原始 `onImageLoad/onLoadFailed` 不被再次调用；Node 不可用时只能报告该行为脚本未执行，不能伪报通过。
- Venera bootstrap/native-network contract必须证明普通 `resolveResource` 的 source-hook `Network.*` 仍可使用 resolver cache，而 `fresh:true` 只对 fresh hook 实际触达的 URL发送 request-scoped fresh marker；host cache回归必须证明 force-miss 只移除该 URL，邻接 cache entry 保留。
- dev.206 ownership gate必须禁止旧 `__zicSemanticRetryConsumed` / `__zicResolveFreshResourceConfig` one-shot fence 回归。
