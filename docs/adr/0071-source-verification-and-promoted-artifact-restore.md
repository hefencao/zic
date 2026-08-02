# ADR 0071: 来源验证投影与 promoted artifact 快速恢复

## Status

Accepted for `0.31.0-dev.87`.

## Context

Cloudflare 可能在来源首页、搜索分页、封面、详情、章节和正文请求任一阶段出现。若各页面按字符串自行判断，会形成多个恢复入口和不一致状态。设备 trace 还显示持久 page artifact 命中时，`Artifact.restore()` 先完整 CRC 扫描，随后 cache store 再读取整文件，5.6–20.0 MB 本地页面单次可耗时约 0.87–4.96 秒。

## Decision

1. Mihon runtime 检查完整 Throwable cause 链，将明确 challenge 投影为 `source-verification-required`；Dart adapter 映射到 domain typed error。
2. UI 只根据 typed error显示 WebView 恢复动作，不对普通 network/decode error 猜测 Cloudflare。来源列表、分页、封面与详情共用 App composition 注入的 network bridge。
3. 新增 `ComicWebUriSource`。Mihon/Venera opaque identity 在 plugin adapter 内解析，Presentation 只获得 URI。详情正常态用 WebView 按钮替代重复刷新按钮。
4. 持久 promoted cache 可调用 `restore(verifyPromotedChecksum: false)`：仅当原子 ready metadata、CRC 格式、记录长度与实际长度均有效时恢复 CRC 状态并跳过重扫；否则完整 rehash。默认 API 仍完整校验。
5. 快速路径只用于 App 私有的已 promote cache read。partial/resume、写入、seal、promote、普通 session restore 和外部文件不得使用该豁免。

## Consequences

- Cloudflare 恢复行为覆盖来源入口而不侵入 Reader/Pipeline。
- 原生来源和其他插件可复用同一 typed error 与 network bridge。
- 大文件缓存命中减少一次完整磁盘扫描，仍保留单次读取及 Pipeline artifact 所有权。
- 同长度磁盘位翻转不会在快速 restore 阶段主动重算；后续 decode/校验失败仍按既有失效链处理。需要设备数据继续评估是否增加低频后台 scrub，而不能恢复每次前台全扫。

## Rejected alternatives

- 每个页面匹配“Cloudflare verification failed”字符串。
- 所有 network error 自动打开 WebView。
- 在详情页保留刷新按钮并另加第二个 WebView 入口。
- App 解析 Mihon/Venera token。
- 本地文件绕过 DownloadSession/Pipeline 直接交给 Reader。
- 为加速关闭完整性校验、删除 metadata 检查或降低预取/lane。
