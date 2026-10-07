# dev.218 source-wake / slider 根因审计

输入：`zic-debug-trace-2026-08-11T07-34-05.jsonl`，基线：dev.217。

## 设备证据

- 新Trace没有上一轮的`sessionBusy/writerBusy`风暴；可观察到15次`downloadPreempted`，说明physical NetLane抢占仍在工作，因此本轮不调整network concurrency/retry/watermark。
- page 334 在38.303095s已经进入decode `waitingSource`；其physical download在38.410022s产生`sourceReady`并在38.431268s完成artifact promotion（约11.3MiB），但40.434913s挂载的page host直到86.713448s释放仍`firstFrameReady=false`，生命周期46,278,535µs。
- 对应DecodeId在source ready后没有重新进入有效decode refill；角色多次晋升current仍保持黑页。该形态排除“图片没下载完”作为主要解释。
- slider操作期间Reader navigation本身可产生大量目标页变化；源码却用`currentIndex`控制Slider.value，而`requestPage`只先写`requestedIndex`，所以连续拖动的受控thumb会被旧current回写。

## 根因

`LiveCoordinator._runDecode()`在directed source wake到达时调用`_nextDecodeRefill(only: id)`。若current bootstrap未满足，`StagedDecodeRefillPolicy`会合法门控 speculative neighbor并返回null。dev.217把该null错误解释为“该source revision已经满足/终止”，立即写入`_decodeSourceRevisions[id]`。之后页面晋升current时，snapshot仍`waitingSource`，但已没有pending source wake，因此eligibility继续为false，形成永久黑页。

## 修复边界

- null policy decision不再等价于source consumption；只有DecodeSession自身证明不需要fill才允许consume。
- available source revision从projection snapshot现态兜底，避免高速role churn只依赖listener edge。
- slider display使用pending request projection，不改变ReaderController/viewport owner。
- 不修改NetLane、download task identity、transport、cache、retry或水位。
