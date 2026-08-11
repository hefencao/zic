# dev.221 resident replay 根因审计

10:30设备Trace中存在current页面长期`firstFrameReady=false`，而相同physical identity已被artifact cache证明有完整大正文。例如page 325附近physical owner持续报告cache-resident约11,631,696 bytes并获得current=1000 demand，却没有late Reader对应的`sourceReady`。

源码审计确认：`begin/append/sealDurableCachedIngress`只推进`_residentLength`并fan-out projection，刻意不写`Artifact`；这是避免同一immutable正文重复落盘/内存的正确所有权。错误位于late join：`attachSynchronizedIngressProjection()`无条件调用`artifact.readChunks(endExclusive: committedLength)`。因此首Reader可在cache stream实时显示，后续Reader面对`committedLength>0`、`artifact.committedLength==0`的promoted session只能重建sealed空projection。

修复不是复制cache bytes回session artifact，而是拆分physical residency与Reader replay authority。session仅要求一个抽象prefix stream；pipeline composition按唯一ArtifactCacheManager或可重开的immutable local source提供它，并继续通过共享artifact-read scheduler。

Trace仍观察到部分physical事件相邻重复；它污染诊断但与本轮sealed-empty projection根因不同，未用该现象驱动下载策略修改。
