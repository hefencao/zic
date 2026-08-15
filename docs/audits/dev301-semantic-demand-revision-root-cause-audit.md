# dev.301 纵排大幅抖动：semantic no-op demand revision 根因审计

## 输入
- 唯一代码基线：dev.300。
- 设备 Trace：`zic-debug-trace-2026-08-15T11-43-44.jsonl`。
- 用户现象：抖动明显，远大于 1–2px；此前 geometry、texture seam、presentation continuity 等局部路线均不足以解释量级。

## Frame cadence
Trace 有 759 个真实 Flutter FrameTiming。基准刷新间隔约 16.4ms；约 37 个 interval 跨 2–4 个刷新周期，约 36 个 >25ms、21 个 >30ms、6 个 >40ms、4 个 >50ms，最大约 73ms。与此同时 raster 中位约 1.9ms、p95约3.7ms且无 >16.7ms；build多数也在数毫秒。代表性滚动长间隔约 52.6ms(build 1.65ms/raster 1.09ms)、46.4ms(5.96/1.17ms)、43.7ms(1.49/0.94ms)。这足以让连续滚动一次跨过几十像素。

## 同步 revision cascade
15.36s 附近 current=12 / target=13 / readDirection=-1。rev46–49 仅随 offscreen WebP cost evidence 计数 8→7→6→5 变化；rev51–54又随 page8→5 `webp-observed` 变成6→7→8→9。各轮仍是11/4/2、2个static warm decode、0 static warm upload、animated flow关闭且frame target全0，却每轮重复4 decodeDemand + 2 uploadDemand。

源码闭环：`PipelineReaderSession._handleSourceKindObserved` 把source sniff微任务送入 `PipelineController.observeWebpTransportCost`；该方法旧实现对任意事实变化 `force:true` replan。`_replan` 先递增 revision，`HeuristicPolicy`令每个 demand `expirationRevision=revision+1`，旧 `DemandDiff` 又用包含 expiration 的对象 equality，于是纯liveness变化被错误升级为 scheduler changed。`ReaderBinding -> LiveCoordinator.reconcile` 同步运行在 UI Dart isolate，changed decode/upload会follow/submit，即使Flutter build/raster很短也可在frame phase之外占住isolate并错过vsync。

## dev.301 收口
- Demand新增明确 `sameSchedulingAs`，不把expiration算进调度identity；普通完整 equality仍保留expiration，避免数据语义含混。
- DemandDiff以scheduling comparator产生semantic diff。
- LiveCoordinator对semantic diff执行资源动作后，再从完整plan刷新surviving demand的expiration；decode/upload task revision不因liveness refresh伪晋升。
- empty download semantic diff直接跳过physical `replaceDemands`。
- PipelineController以candidate revision建plan；window/target未变且semantic diff为空时，不提交revision/update，但runtime evidence仍被记录以影响未来真正相关的计划。
- Reader FrameTiming删除错误的batch callback-time scroll/current/interaction关联，增加batch index/size/callback monotonic/last-vsync anchors。

## 验证目标
下一份Trace应看到source/media evidence事件继续存在，但语义无变化时revision保持不变，且不再出现成串4 decode + 2 upload demand replay。真实current/transition、decode-target或animated flow变化必须仍生成有效delta。
