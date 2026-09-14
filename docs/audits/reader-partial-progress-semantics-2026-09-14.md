# Reader partial / network progress semantics audit — 2026-09-14

## 结论

本轮先核对 physical 文件与 SQLite，再改 presentation。用户报告的两类现象都不能靠“动画看起来完整”判断文件是否完整：durable partial、当前 network cursor、Reader-local 可解码 prefix 是不同事实。但它们不需要在 UI 中拆成两条进度；最终合同是一条共享横向尺度。

## 原始证据

page274 的 durable partial 为 1,277,952 / 13,452,374B。它立即 queued，但 source open 约 4.83s 后才返回；随后 HTTP206 从 1,277,952 精确续传。因此旧 UI 在 source open 前缺少 connecting 活动是 projection 问题，不是 partial 丢失。

page25 的 canonical physical partial 为 12,329,700B，而 origin full length 为 15,640,724B。服务器忽略 Range、返回 HTTP200 后，当前 attempt 从 byte0 full-body catch-up；旧 trace 退出时 network cursor 约 5.42MiB，小于 preserved partial，但 decoder 已能从 preserved prefix 观察到 301 帧。Animated WebP 能循环很多/全部可见帧并不证明 EOF/tail metadata 已完整。

## 本地 total 不应等待网络

旧 page25 partial 的 SAF sidecar 实际 `totalLength:null`，这解释了为什么旧 projection 一度认为“比例未知”。但正文前 64B 已在本地，且其 RIFF/WEBP header 的 bytes 4..7 声明完整 RIFF payload 长度。真机直接读该 partial 的前 64B 得到 declared total **15,640,724B**；fresh profile 随后真实 HTTP200 response 报出的 total 也是 **15,640,724B**，二者完全一致。

因此 `DownloadSession` 现在只读投影 `localEncodedTotalLengthHint`：durable `totalLength` 已知时仍优先使用；旧 WebP partial 缺 total 时，从本地 RIFF header 计算 `uint32le@4 + 8`。这个值不能写回 durable `_totalLength`，也不能参与 validator、resume、seal、promotion、cache 或 scheduler，只用于显示尺度。真正无法从本地 metadata/container 得到 total 时，UI 不得用固定短条、虚线或任意宽度伪造比例。

## 单尺度呈现

Reader progress 只有一条横向尺度：

- transport wave 表示 `0..networkCursorLength`；
- 若 transport cursor 小于 authoritative `committedLength`，只把 `cursor..committedLength` 这一段画成直线 partial；
- transport 追平或超过 partial 后，不再显示独立 partial 段；
- queued/opening 尚无 body cursor 时，同一条线上可显示 1.5px indeterminate connecting activity；
- active response 的 `networkAttemptTotalLength` 可在 overlap/catch-up 尚未完成时临时提供显示尺度，但仍不是 durable authority。

这样 full-body catch-up 从0重读时，用户同时看到“网络追到哪里”和“本地已经有到哪里”，又不会把同一事实重复成上下两条进度。

## Fresh device validation

11:34 profile APK 以 `adb install -r` 覆盖安装，数据保留、`low_power=0`。fresh trace `.log/zic-debug-trace-2026-09-14T03-39-37.jsonl` 重新命中 `single2:25`：local prepare 恢复 12,329,700B；约 4.62s 后 origin HTTP200 报 total=15,640,724B；Reader 退出前 durable physical partial 已增长到 13,661,220B。整个过程继续使用同一 canonical physical owner。

widget regressions机械验证单lane geometry，包括真实 page25 数值下的 `wave 0..5,423,900` + `straight 5,423,900..12,329,700`，以及 transport>=partial 后 partial mark 消失。focused tests：DownloadSession 2/2、Pipeline progress 7/7、Reader indicator 6/6；全量 Sessions、PipelineRuntime、ReaderRuntime、Downloads 均 exit0，Downloads 401/401。
