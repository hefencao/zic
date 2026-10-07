# dev.181 根因审计：生产 read-through cache 擦除了 current TaskControl

## 输入

- `zic-debug-trace-2026-08-09T05-00-31.jsonl`
- dev.180 唯一代码基线
- 只读 `vibevenera-master.zip`

## Trace结论

- cache/hot revisit已经很快：部分页面 mount→first-frame约十几到数百毫秒，说明统一artifact读取、native decode与presentation不是所有慢页的共同根因。
- origin current仍有明显秒级长尾。典型 current page 62在 network lane 已以priority 1000进入5+1 handoff后，`source-loader` origin open仍约8.58秒；response可用后约90毫秒即可首帧。
- rhttp framing已生效：origin logical chunks以约64KiB首块、约256KiB后续进入Pipeline。因此本轮不再调整framing、7/3窗口或decode水位。

## 代码根因

生产 `PipelineReaderSession._transportFor()` 在artifact cache存在时总返回 `ArtifactCacheTransport`。`DownloadJob`只有在最外层transport实现 `ControlledTransport`时才调用 `openControlled(... control: CancelToken)`；但dev.180 `ArtifactCacheTransport`只实现普通`Transport`，cache miss又无条件调用`fallback.open()`。

因此真实origin链变成：

`CancelToken --X--> ArtifactCacheTransport -> LoaderTransport(control capability unused) -> Venera`

这解释了为什么dev.175以后底层控制面测试可通过，但生产current仍有时无法在Venera source-plan队列中体现priority/cancel。

## VibeVenera对照

当前VibeVenera也在图片下载附近调用`getImageLoadingConfig/onImageLoad`，并非预先解析整章媒体request-plan。因此不能把“预解析371页plan”当成忠实迁移方案。应先保证调度任务身份不会在缓存wrapper中丢失。

## 修复

- `ArtifactCacheTransport implements ControlledTransport`。
- ordinary `open`委托controlled入口。
- cache miss若fallback支持controlled capability，则原样传递同一个`TaskControl`。
- cancellation在cache与origin边界保持权威；cancelled任务不得因为cache miss继续打开origin。
- origin telemetry新增`controlledFallback`和实时priority。
- 新增行为回归和dev.181无Dart静态gate，锁定生产composition中的read-through capability。

## 未改变

- NetLane/5+1 handoff算法。
- retained receiving与短时回切复用。
- Venera单 invocation gate及pressure-only preemption。
- rhttp 0.18.0、64/256KiB framing。
- native source lock、artifact checksum优化。
- encoded 7/3、decode 2/1、network/decode/upload 5/3/2。
