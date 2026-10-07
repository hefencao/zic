# ADR 0073：来源 Cookie 会话与章节目录稳定性

- 状态：Accepted
- 版本：0.31.0-dev.89

## 背景

Cloudflare clearance 可能同时绑定 Cookie、User-Agent、站点和网络环境。dev.88 虽然建立了可见 WebView 与原子 Cookie 快照，但浏览器仍可能使用默认 WebView UA，而 Mihon OkHttp 使用固定 UA；Venera runtime 也使用自己的 WebView UA。结果是 Cookie 看似已导入，却在短时间内再次被站点拒绝。

同时，详情初始化刷新与手势刷新可能重叠。旧实现把“已有刷新正在运行”当作 `false` 返回，导致章节列表由先发请求成功更新，而刷新 Presentation 显示红叉。Mihon 又把任意根因 `UnsupportedOperationException` 视为“目录能力不存在”，可能在短时验证失败后错误回退 synthetic 单章节。

## 决策

1. 来源 runtime descriptor 可声明 `browserUserAgent`。App 通过 `ComicWebViewRequest` 将 URL 和 UA 原子传给 `network_bridge`。
2. 可见 WebView 与来源 HTTP 必须使用同一 UA；浏览器快照读取可要求精确 UA 匹配。
3. `AndroidBrowserCookieSession` 是 Android 进程间 Cookie handoff 的唯一实现。Mihon `AndroidCookieJar` 和 Venera runtime 在读取自己的进程内 CookieManager 前导入快照。
4. 不共享 WebView data directory。App 浏览器留在主进程；插件 runtime 在首次 WebView/CookieManager 初始化前配置独立 suffix。跨进程共享使用原子文件快照。
5. 同一详情刷新共享一个 in-flight Future。刷新结果成功/失败显示 2 秒后消失。
6. Mihon synthetic revision 升至 3。runtime 记录已观察到真实目录的 source/comic identity；App 持久层拒绝空目录或 synthetic-only 覆盖已有真实目录。
7. `UnsupportedOperationException` 只有来自共享 Mihon ABI 默认实现时才代表能力缺失。扩展自身解析器抛出的 UOE 属于失败。
8. 增加来源和详情 Trace，但禁止记录 Cookie 值、localStorage 值或完整 opaque token。
9. 远程详情刷新只能调用 App composition 的原子刷新 facade。该 facade 负责来源加载、真实目录回归检查、持久化和只读快照返回；详情 Presentation 不得直接调用 `source.loadComic` 后自行替换 manifest。

## 原因

WebView 的 data directory 包含数据库、锁、缓存和 Chromium 私有状态，不是跨进程 API。Android 多进程 WebView 要求不同进程在首次初始化前设置不同 suffix；强制共用目录会引发初始化异常、锁冲突和数据损坏。原子快照只传递宿主明确需要的会话数据，并可执行站点、UA、时效和日志脱敏约束。

## 后果

- Mihon 与 Venera 都能使用可见浏览器产生的匹配 Cookie。
- Android 原生网络实现可复用相同 importer/jar；Dart 原生源仍需由 network/transport composition 显式注入会话能力。
- 真正无目录的 gallery 仍可使用 revision 3 synthetic，但短时网络/验证失败不能再伪装为 gallery。
- 如果站点还绑定 TLS 指纹或 IP，WebView Cookie 仍可能被 OkHttp 拒绝；Trace 将显示浏览器快照和后续目录失败，便于进一步定位，而不是恢复 synthetic 掩盖。
