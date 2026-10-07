# dev.191 Venera Network Cache 根因审计

## 真机证据

输入：`zic-debug-trace-2026-08-09T14-12-27.jsonl`，dev.190。

18个origin request-plan样本：

- `sourceRequestPlanMicros`：median 3.016s，p90 5.209s，max 7.248s；
- `sourcePlanGateWaitMicros`：median 1.742s，p90 3.593s，max 5.253s；
- `sourcePlanRuntimeInvocationMicros`：median 1.398s；
- `sourcePlanHookMicros`：median 1.392s；
- `sourcePlanBridgeNetworkMicros`：median 1.368s；
- `sourceHostOpenMicros`：median 0.745s；另有单个17.424s真实host-open网络长尾；
- `sourcePlanBridgeNetworkCalls`：18/18全部为4。

因此dev.189 current-only动态抢占已不再是主要回归；稳定的结构性问题是每个per-image plan都重复执行约1.4s bridge resolver网络，single-invocation再累积为gate wait。

## Source contract 对照

当前E-Hentai source的`loadThumbnails`与`getKey`都请求`cache-time: long`和`prevent-parallel: true`。`onImageLoad`先取first thumbnails和key；非首thumbnail page再取对应gallery page，之后POST API得到最终图片URL。当前Venera app的network cache会对`long` GET在6小时内直接复用，并把`cache-time`、`prevent-parallel`作为控制字段而非origin header。

ZIC dev.190 `VeneraNativeBridge.performHttp`没有读取上述控制字段，`veneraRequestHeaders`也未剥离它们，且没有runtime network cache。这解释了trace中每页固定4次bridge network。

## 修改边界

只修改plugin runtime Network兼容层：增加有界GET cache、剥离control headers和cache hit/origin diagnostics。不修改NetLane、Reader窗口、Pipeline artifact/cache、最终图片transport、Mihon/Cloudflare或Venera JS并发。
