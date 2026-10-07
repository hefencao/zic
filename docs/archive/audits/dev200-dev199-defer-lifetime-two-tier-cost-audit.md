# dev.200：dev.199 defer 生命周期与 very-large catch-up 成本审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.199_cost-aware-full-body-catchup-admission.zip`。
- 真机 trace：`zic-debug-trace-2026-08-10T08-46-42(1).jsonl`。

## 网络归账

- trace：8136 events，约2.72 MB；
- origin `sourceRead`：45条，约245.59 MiB；
- `duplicatePrefixBytes`：约40.96 MiB，占约16.68%；
- strong-validator Range：6次accepted，继续是206/direct/duplicate=0；
- `full-body-prefix-catchup-deferred`：9次，涉及6个DownloadId。

按full-body attempt开始时的source priority归账，有重复字节的terminal事件约22.10 MiB来自priority1000，约18.86 MiB来自priority820。1000属于当前页必要增长，不应为降低统计数字而defer；820中最大问题来自同一9.14 MiB partial：一次catch-up在旧boundary前重复5.09 MiB后abort，后续又完整重复9.14 MiB，合计约13.57 MiB。

## dev.199 生命周期缺口

`LiveCoordinator`用`Set<DownloadId> _downloadDeferred`阻止同一active demand内的800→780等角色变化重新联网，但`diff.removed`对idle session调用`_retireDownloadTracking()`，该函数无条件删除deferred项。于是页面离开窗口、稍后再次以低priority出现时，仍会重新Range probe。

trace中：

- `4bbd...`（约5.43 MiB）在三个独立780 demand窗口发生3次`full-body-prefix-catchup-deferred`；
- `5430...`（约11.95 MiB）在800与760窗口发生2次defer；
- 这些重复defer未读取full body，但对应5次host-open累计约3.68s。

因此“defer只属于当前network task/demand tracking生命周期”不足以表达真实成本：需要记住的是**当前DownloadId在当前committed boundary已经确认低优先级full-body不值得执行**，而不是endpoint能力。

## dev.200选择

1. `_downloadDeferred`改为`DownloadId -> committedLength`；仅当当前session仍idle且length完全匹配时跨demand detach保留。
2. re-add/change时，如果length变化或当前priority达到admission门槛，清除defer并重新probe。
3. 成功/promotion/dispose清除defer；不持久化到disk，也不按endpoint/hash建表。
4. admission改为两级：1–8 MiB需要>=820，>=8 MiB需要>=900；<1 MiB维持任意priority。
5. 不修改DownloadJob的Range/CRC proof，不修改DownloadSession artifact authority，不修改DecodeSession、Reader/Pipeline、NetLane或network=5。

## 预期真机信号

- 同一committedLength的低priority page在detach→re-add后不应再次出现`downloadStarted/artifactSource/full-body-prefix-catchup-deferred`；
- 8 MiB以上partial在priority820不应启动full-body attempt，升到900/1000后才重新probe；
- 1–8 MiB partial在820仍可继续；
- current=1000的`duplicatePrefixBytes`仍可能较高，这是服务器不支持Range时必要成本，不应通过阻断current来“优化”。
