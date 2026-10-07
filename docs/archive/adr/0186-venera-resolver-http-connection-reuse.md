# ADR 0186：Venera resolver HTTP 完整响应连接复用

## 状态

Superseded by ADR 0188；不再优化 Kotlin HttpURLConnection，resolver HTTP owner 已迁到 rhttp。

## 背景

11:48 真机trace继续显示 request-plan cold miss 的中位耗时约1.34秒，而cache hit仅为微秒级。current miss的gate wait通常很低，主要时间位于自己的`onImageLoad` bridge Network调用。ZIC native Venera bridge使用`HttpURLConnection`执行这些Network调用；此前即使response body已完整读取，也在finally无条件`disconnect()`，使同一次resolver中连续origin请求无法稳定利用平台HTTP/1.1连接池。

## 决策

1. 保持Venera JavaScript单invocation、Network cache、cookie/auth/header identity、redirect和requestId cancellation语义不变。
2. `httpWithUrlConnection`必须完整读取并显式关闭response InputStream。完整成功后不主动`disconnect()`，让Android底层HTTP连接有机会回到平台连接池供后续resolver origin请求复用。
3. 未完整消费、异常或request-scoped cancellation仍必须立即`disconnect()`；`cancelConnection()`继续同时关闭InputStream/connection，物理取消边界不变。
4. 不增加Venera并发，不引入第二transport scheduler，不把resolver连接复用扩展为Reader正文transport owner。
5. 现有`sourcePlanBridgeNetworkMicros/cacheHits/originCalls`继续作为效果观测；不得反馈为scheduler policy。

## 风险边界

连接是否最终复用仍由平台/服务器Keep-Alive条件决定；本决策只移除ZIC主动破坏复用的行为，不承诺每次请求复用同一socket。
