# ADR 0337：External presentation grant 原子发布与 attempt-scoped 退出

状态：Accepted

## Context

ADR 0336 修复了 detached raster eviction 后 same-identity 无法重新 grant 的主故障，但对
`27467b96` 继续做 current-tree 反审计后，presentation handoff 仍有五个相互关联的状态漏洞：

1. `LocalImagePlayer._reportedFirstFrame` 按 widget lifetime 去重；same-generation regrant 虽能重新显示，
   却不能再次确认本次 grant 的 first frame。
2. `PipelinePresentationRasterCache` 的 raster decode error 先同步按 ordinary eviction 通知 Pipeline，
   UI 会先退休 provider/read authority，随后真实 error channel 无法交给 recovery。
3. `requested=false` 与 `ready=true` 分两次同步发布，正常首帧本身制造瞬时
   `(false,false)`，UI 把它解释成真实 revoke 并重载。
4. widget 级 `_recoveryInFlight` 会阻塞恢复期间到达的新 presentation identity/grant。
5. 旧 attempt 的异步 recovery 返回后只检查 `mounted`，可能把已经 ready 的新 attempt 标成 invalid。

这些都不是新的 transport/cache failure；共同根因是把“本次 presentation attempt 的局部退出状态”
和 widget lifetime / 两个独立布尔投影混在一起。

## Decision

1. `PipelinePageOutputStream` 对 external-static 只发布一个不可变 `PipelineExternalPresentationGrant`。grant内部私有绑定exact `DecodeId`，Presentation可见字段只有`cacheIdentity + state(unavailable/requested/ready) + acknowledgementToken`；这样ack仍能回到exact Pipeline identity，同时保持ADR 0061的opaque output边界。
   兼容只读 getter `externalPresentationRequested/Ready/CacheIdentity` 只能从该 grant 派生，不再分别拥有状态。
   `requested -> ready` 不得经过可观察的 `(false,false)` 中间态；cache identity 也不得作为独立 setter 先后通知 UI。
2. 每次 available grant 都拥有 acknowledgement token。`requested -> ready` 保留同一 token；ordinary same-cache-identity revoke/regrant 必须得到新 token，presentation cache identity 本身仍保持稳定。mounted first-frame 只能携带其实际消费的 grant 回报给 `PipelinePageOutputStream.reportExternalPresentationFrameReady(grant)`；output 先验证 token 仍是 current，再由pipeline_runtime读取grant私有的 exact `DecodeId`交给session。旧 callback 不再按 `PageAsset` 反查当前 DecodeId，Presentation也没有DecodeId getter，因此不能满足 replacement/regrant或接管decode identity。
3. `LocalImagePlayer` 的 first-frame 去重仍按当前 `_loadEpoch`，而 error scheduling、exact read authority、automatic recovery 与最终 invalid 发布共享不可变
   `_PresentationAttempt(loadEpoch, token, presentationGrantToken, authority)`。grant token 改变会退休旧 local binding；任意 `await` 后若 attempt 已不是 current，旧结果不得发布 UI 状态、不得确认新 grant、不得重启新资源。
4. recovery ownership 也按 attempt epoch 记录。新 grant / load epoch 可以 supersede 旧 recovery；
   同一个 attempt 的重复 error 只 join/视为已有 owner，不创建第二个 recovery。
5. managed raster decode failure 不等于 ordinary residency eviction。
   cache owner 在 completer error 时只退休失败 entry，不能先同步发 eviction notification 销毁 mounted error channel。
   当前 consumer 必须先得到 error 与原 exact read authority；只有 exact artifact rejection 才能按 ADR 0336
   进入 durable recovery。
6. WebP metadata prefix 读取是同步 API。旧 `async _drainStreamingWebpPrefix` 没有任何 `await`，
   因而其 syncing、双 revision、while 与递归补调度不能产生真实并发保护，删除后只保留单调
   `metadataPrefixLength` 去重与同步 prefix parse。
7. 不新增 Reader-local retry/cache/scheduler owner，不扩大 7/3、2/1、NetLane、decode/upload/presentation/raster budget。

## Regression

`external_presentation_generation_test` / `page_loading_indicator_test` 覆盖：

- 正常 mounted first-frame 从 requested 原子切到 ready，encoded load 只发生一次；
- stale first-frame acknowledgement 不能满足 same-cache-identity 的 replacement regrant，current grant token 才能完成 ready；
- raster eviction 后 same presentation identity regrant 会再次得到 mounted first-frame confirmation；
- corrupt managed raster 的 error callback 能拿到原 exact presentation authority；
- old recovery pending 时新的 DecodeTarget/presentation identity 仍可加载并 ready；
- A 的旧 rendered-error recovery 完成后不能把已经 ready 的 B 标成 invalid。

这些行为回归与 ADR 0336 的 same-identity residency 回归共同定义 current presentation handoff。
