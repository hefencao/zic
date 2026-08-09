# dev.178 根因审计：ZIC / VibeVenera 首播延迟差距

## 输入

- `zic-debug-trace-2026-08-09T01-44-16.jsonl`
- 只读参考：文件库权威 `vibevenera-master.zip`

## Trace分段

本次trace共2868条事件。remote first-frame样本约3.66s、7.41s、8.69s；cached/已驻留样本约33–223ms。

page 193：current约28.046s开始，约31.756s才取得origin source，source/open约3.71s；随后从约24.6KiB增长到可解首帧约286.7KiB又用约4.9s。first-frame timing中的`sourceWaitMicros≈8.67s`，而`nativeDecodeMicros≈62ms`。因此decode本身不是6–8秒主因。

page 141：current约69.90s启动，约73.36s取得origin，source/open约3.44s，mount到首帧约3.66s。相邻请求也出现约2.31s source/open。

dev.175/176已收口的native ingress与artifact CRC热点在本trace中保持较低量级，没有证据支持回滚这些修改。

## 与VibeVenera结构差异

VibeVenera同样保留download前7/后3、decode前2/后1，并没有用关闭预下载换首帧。其图片主下载使用rhttp/Rust流式传输；ZIC生产shared source host transport仍以Dart`HttpClient`执行已解析request plan。这一HTTP engine差异位于当前trace最大等待段上，且可通过既有platform direct transport injection替换而不改变Pipeline所有权。

## 修复边界

- 仅替换Flutter生产source-media host HTTP engine；不改source schema、Reader demand、NetLane、DownloadSession/artifact、decoder水位。
- direct platform transport必须接受同一个`TaskControl`，保留cancel/range/validator/source client mismatch语义。
- 不增加rhttp→Dart HTTP的第二生产fallback；未注入platform transport的pure/test composition才使用core HttpClient。
- 后续设备trace若仍慢，必须继续按plan/open与prefix吞吐分段，不能回到缩窗口或增加并发。
