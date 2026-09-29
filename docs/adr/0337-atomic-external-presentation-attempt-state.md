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

1. `PipelinePageOutputStream` 仍保留公开只读 `externalPresentationRequested` /
   `externalPresentationReady`，但内部只能通过一次
   `_setExternalPresentationState(requested:, ready:)` 原子提交完整状态。
   `requested -> ready` 不得经过可观察的 `(false,false)` 中间态。
2. mounted first-frame confirmation 按当前 `LocalImagePlayer._loadEpoch` / presentation attempt 去重，
   不按 widget lifetime 去重。ordinary same-generation revoke/regrant 会退休旧 attempt 并取得新 epoch，
   因此本次 grant 可以重新确认 first frame，而 presentation identity 本身仍保持不变。
3. error scheduling、exact read authority、automatic recovery 与最终 invalid 发布必须共享同一个不可变
   `_PresentationAttempt(loadEpoch, token, presentationIdentity, authority)`。
   任意 `await` 后若 attempt 已不是 current，旧结果不得发布 UI 状态、不得重启新资源。
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
- raster eviction 后 same presentation identity regrant 会再次得到 mounted first-frame confirmation；
- corrupt managed raster 的 error callback 能拿到原 exact presentation authority；
- old recovery pending 时新的 DecodeTarget/presentation identity 仍可加载并 ready；
- A 的旧 rendered-error recovery 完成后不能把已经 ready 的 B 标成 invalid。

这些行为回归与 ADR 0336 的 same-identity residency 回归共同定义 current presentation handoff。
