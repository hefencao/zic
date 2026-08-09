# ADR 0161：VibeVenera Rust Streaming Transport 首播路径

状态：Accepted

## 背景

dev.178设备trace显示remote首次播放常见3.6–8.7秒，而cached页约30–220ms。慢页首帧native decode/upload只有几十毫秒；关键路径是source/request-plan/open约2–4秒，以及origin response开始后为了得到约250–300 KiB可解码WebP前缀继续等待数秒。dev.175–176已经把native source锁和逐chunk CRC热点压到微秒/亚毫秒量级，因此继续优化decoder不是当前最大收益。

权威VibeVenera源码保持与ZIC相同的download/decode工作窗口与network/decode/upload并发级别，但主图片下载使用Rust/rhttp流式HTTP；Dart IO client只属于兼容/失败路径。ZIC当前生产host media仍使用`dart:io HttpClient`。

## 决策

1. 不改变encoded 7/3、decode 2/1、network/decode/upload 5/3/2、reserved current 1、retained-receiving与pressure-preemption。
2. `downloads`定义`SourceResourceDirectTransport` composition能力，接收同一个`TaskControl`并由`ExternalPluginResourceTransportPool`关闭；它不拥有retry/prefetch/priority policy。
3. Flutter生产composition在`downloads_bridge`注入`RhttpSourceResourceDirectTransport`；pure `downloads`继续保留已有Dart HttpClient作为非Flutter/test默认，不把Flutter/Rust依赖下沉到core。
4. rhttp固定0.13.0以保持ZIC Dart>=3.6兼容。App首帧后后台预热`Rhttp.init()`；transport复用一个client并启用keep-alive。
5. 平台transport继续执行source已解析request plan：method/headers/body/range/validator保持；关闭自动redirect与status throw；`Set-Cookie`、redirect、非媒体prefix继续视为source client state/protocol mismatch并交现有source-owned兼容路径。
6. scheduler cancellation必须覆盖rhttp request与response body全生命周期；不得因换HTTP engine丢失dev.175–176的TaskControl语义。
7. 不在生产同时启动rhttp和Dart HttpClient竞争同一个媒体请求。Dart实现只有composition未注入platform transport时才存在。

## 后续

真机先测同一source/device的mount→plan→origin→prefix→first-frame。若rhttp后plan仍显著超过2秒，下一步优化Venera request-plan预热/缓存；若origin快而前缀仍慢，再按HTTP版本/吞吐下钻，不缩预下载窗口。
