# ADR 0308：Venera source semantic recovery chain

状态：Accepted；取代 ADR 0304 的第 3、4、6、7 项 one-shot recovery 决策。

## 触发证据

最新真机 trace 中某 Reader page 的 physical session 在 `committedLength=0`、`local-hydration-miss` 后首次进入 source network，最终以 `source image recovery returned non-media bytes` 结束；因此该失败与 partial、cache 或 decoder 无关。源码复审确认 ADR 0304 把 initial non-media 后的 source recovery 限制成一次 replacement，并在 replacement 再次返回 non-media 时直接转 terminal。

与 `~/projects/vibevenera/lib/network/images.dart` 对照后确认这不是 Venera 的原生语义：VibeVenera 由单一 image-download owner 持有 `retry=5`，每次当前 `ImageLoadingConfig` 失败后都可调用**当前 config** 的 `onLoadFailed` 生成下一 config；replacement 可以继续携带自己的 `onLoadFailed`。它不会因为已经产生过一次 replacement 就重新执行最初的 `onImageLoad`。

## 决策

1. `sourceMediaSemanticRejected` 与 `sourceClientStateRequired` 的 ADR 0304 分离继续有效；host/rhttp 的 image-media signature 校验继续严格拒绝 HTML/文本/其它 non-media bytes，绝不通过放宽 magic 校验修复恢复问题。
2. source semantic recovery 仍只有一个 owner。`SourceResourceTransport` 在一次 logical open 内最多消费 5 个 source-defined replacement config；replacement 再发生 semantic rejection时继续请求当前 source state 的下一 replacement，而不是交还 DownloadJob/provider RetryPolicy 新建另一层 semantic retry。
3. Venera runtime 为 retained image config 持有 `__zicSemanticRetryCount`，初始为 0，上限为 5。`retryResource` 只能调用当前 retained config 的 `onLoadFailed`，replacement 继承 `count+1` 并可携带新的 `onLoadFailed`；达到上限或当前 config 没有 callback 时返回 unavailable。
4. external streaming `retryResource` 与 full-runtime `loadResource` 必须共享同一 retained config 和同一 count。若 streaming 已消费 N 次，而 replacement 因 transform/client-state 进入 runtime，runtime 只能继续剩余 `5-N` 次；不得重新运行原始 `onImageLoad`，也不得另起一份 5 次预算。
5. source chain耗尽后仍转为 non-retryable `ErrorCode.source` / `sourceSemanticRetryExhausted`。这不改变 provider network retry 数量、NetLane admission、open/read watchdog、Reader 3/7、decode 2/1、partial persistence或cache authority。
6. 独立的新 image identity/runtime generation 可以从其正常 `onImageLoad` 建立新的初始 config；同一 retained logical resource 的失败链不得以“fresh resolve original config”逃逸当前预算。

## 验证

- downloads 行为回归必须覆盖 `original bad -> replacement bad -> replacement good`，证明第二 replacement 由同一次 source recovery owner消费。
- downloads 行为回归必须覆盖 5 个 replacement 全部 semantic reject，并断言第 6 次 `retryResource` 永不发生。
- Venera bootstrap contract必须证明 external retry 后 runtime fallback继续当前 replacement 的 `onLoadFailed`，同时原始 `onImageLoad/onLoadFailed` 不被再次调用；Node 不可用时只能报告该行为脚本未执行，不能伪报通过。
- dev.206 ownership gate必须禁止旧 `__zicSemanticRetryConsumed` / `__zicResolveFreshResourceConfig` one-shot fence 回归。
