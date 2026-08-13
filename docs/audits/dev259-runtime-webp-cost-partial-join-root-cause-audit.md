# dev.259 根因审计：动画流控未激活与 Reader partial source 冷启动

## 设备证据
基线：dev.258；Trace：`zic-debug-trace-2026-08-13T08-03-43.jsonl`。

- 59 次 `policyDecision` 全部 `animatedFlowActive=false`，3/7 内全部 `flowTargetFrames=0`；整场 `mediaClassified=0`。因此 dev.258 的 decoder playable-prefix gate在本次主路径上根本没有机会成为远端 suspension policy。
- Reader 初始 current=206 时有 11 个 download demand，但 normal network limit=5；最先实际 `downloadStarted` 的正好是 current/next1/next2/previous1/next3 五页，全部 `flowTargetFrames=0`。next4 及更远页面只有 demand、没有 transport attempt。
- 页面向前移动时，旧窗口 receiving task 的最后 claim可变成 `receivingRetained=true` / rank0。Trace 有 7 次 current `downloadPreempted`；partial均 `partialPreserved=true, partialState=idle`，说明 dev.255 的partial validity修复成立，但旧 unlimited body仍在消耗 slot，直到新 current用reserved/preemption抢占。
- page210 首次 mount→first frame约1.88s；随后反向重访同页只约18ms。该差异与“首次向前时尚未获得足够前景资源/连接、返回时已有Reader-local decode/output状态”一致。

## 根因
对 opaque `venera-resource:`，manifest既没有 `.webp` extension也没有 `ContentKindHint.webp`。Pipeline 的 bounded WebP flow 又依赖 manifest hint或 decoder runtime animation classification；后者只在完整 animation metadata 可用时产生。因此形成循环依赖：

`无WebP hint → animatedFlowActive=false → target0/unlimited → normal5被大body占满 → 远端不连接/完整metadata更慢 → 无mediaClassified → 继续target0`。

这比“partial不够decoder playable prefix”更上游；dev.258 的问题是真实 bug，但不是08:03运行的主因。

另一个独立但相关的 ownership漏口来自 Reader cold join：physical partial 的 committed bytes可以立即投影到进度条，但新的 Reader-local ingress必须重放 encoded bytes后decoder才可看到 source。旧实现把“追平全部 committed partial”当成“source可以发布”的条件，导致大 partial 的本地恢复延迟直接进入首帧路径。该点由源码生命周期确认；08:03 初始 current本身从0开始，故此 Trace不是该现象的直接复现证据。

## 收口
- runtime ingress sniff到WebP只产生 transport-cost evidence，不产生animation truth；authoritative static/animated仍归decoder。
- cost evidence足以使完整3/7 demand获得既有5/3/2/1 positive flow target，从而让远端body达到credit后释放/暂停，而不是五条unlimited body长期占槽。
- nonresident WebP late join先发布decoder最小可播放prefix，再在同一native source上追平剩余physical partial；不新增第二physical/artifact owner。
- 远端network-need仍由TransferOwner唯一判断；不引入“partial bytes大于某阈值即不下载”的平行策略。
