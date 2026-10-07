# ADR 0372：Mihon canonical 默认客户端的 host replay 能力

**状态：Accepted**

## 根因

真实设备隔离验收的 9 个 Mihon source page plan 全部标记
`requiresRuntimeTransform=true`，图片进入完整 runtime 正文路径。
当前 `NetworkHelper.client` 已安装 canonical
`UncaughtExceptionInterceptor`、`UserAgentInterceptor`、`CloudflareInterceptor`，
但 host replay 能力白名单仍只认识历史 `NetworkHelper*` 与 bridge Cloudflare 类型。
标准 host-owned 客户端因此被误判为未知能力。
JVM failing-first 使用独立 source classloader 和三个 canonical 类型，确认该误判。

## 决策与边界

在既有能力判断中加入这三个精确类型。保留 source classloader 优先拒绝，
未知或插件自定义 application/network interceptor 仍要求 runtime 执行。
不放宽为整个 interceptor 包，也不删除标准客户端 interceptor 或更改其行为。

完整 imageRequest method、headers、body 与同步 Cookie/browser UA 仍由 plugin host 拥有。
普通可重放媒体使用现有 host streaming；响应 redirect、Set-Cookie 与协议状态
仍在同一 scheduler TaskControl 中进入既有 source-client compatibility，
非媒体 2xx prefix 仍在 decoder 前拒绝。
真实 extension transform 继续使用原 runtime/payload-bound revision。

不修改 NetLane、取消真实退出、Reader observation、worker、7/3、2/1 或预算。
该缺陷证明普通图片不必要的完整跨进程传输，不能单独归因全部可见 Reader 卡顿。

## 验证

JVM before/after 覆盖标准 default client、未知能力与独立 source-loader 的自定义能力；
真实来源合同验收包括 catalog 重取、request plan、host ingress、fresh generation、
六个普通来源变体的 cover/page host streaming、五个插件重启，以及 production rhttp 非媒体 200 拒绝。
WNACG 当前 payload 安装自定义 response/mirror interceptor 与 compression 能力，
仍走 runtime；其 cover/page 直连与可控协议回退要求保持未验，不能由成功解码关闭。
详细范围及未验条件见 `docs/archive/audits/source-contract-acceptance-2026-10-02.json`。
