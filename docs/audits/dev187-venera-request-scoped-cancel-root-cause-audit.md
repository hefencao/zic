# dev.187 Venera request-scoped cancel 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.186_venera-previous-request-plan-pressure-source-open-stages.zip`。
- 设备证据：`zic-debug-trace-2026-08-09T10-30-21.jsonl`。
- 只读参考：文件库 VibeVenera 源码；仅比较 bridge delay/网络取消语义，不复制第二套调度器。

## 结论

dev.185/186已经让外层NetLane与Venera gate具备previous/current pressure语义，但dev.186的新stage diagnostics表明剩余几秒主要仍发生在request-plan。18个origin样本中：

- `readMicros`中位约4.098s；
- `sourceRequestPlanMicros`中位约3.195s；
- `sourceHostOpenMicros`中位约0.367s；
- request-plan/read占比中位约83%。

因此本轮不继续改priority/并发。

## 物理取消缺口

1. ZIC Venera native bridge把插件 `delay`实现为同步 `Thread.sleep`。即使外部requestId已经被cancel，sleep本身也不能由现有connection cancellation唤醒；而VibeVenera对应路径是异步delay。设备trace不能证明31s样本具体正在执行哪个bridge method，因此这里只把blocking delay认定为代码级取消风险，不把它伪装成已观测到的唯一根因。
2. ZIC request-scoped cancel跟踪了HTTP connection/call，但response body读取使用的`InputStream`未加入同一requestId集合。对于已经进入blocking body read的请求，缺少“close当前reader”这个直接physical-abort seam。

## 修改

- `delay`改成JavaScript async timer/Promise；每个timer绑定requestId，cancel时clear + reject。
- native `delay`禁止再sleep。
- URLConnection与DNS-fallback的response `InputStream`在read期间register/unregister，request cancellation主动close。
- 唯一JavaScript invocation permit仍只在真实`finished(requestId)`后释放。

## 未修改

- Reader encoded 7/3、decode 2/1、holder 7/5/3/2；
- normal network/decode/upload 5/3/2；
- current=1000、previous=780、threshold=40、current reserved=1；
- rhttp framing、artifact/cache/retry ownership；
- Mihon/Cloudflare。
