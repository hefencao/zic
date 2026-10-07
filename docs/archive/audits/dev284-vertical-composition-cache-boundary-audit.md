# dev.284 纵向 composition cache 边界抖动审计

## 设备事实

输入：`zic-debug-trace-2026-08-14T15-33-48.jsonl`（dev.283）。用户观察为“特定区域无论上下滑都明显抖动，疑似分界位置”。

- dev.283 target合同已闭合：`visibleIndexes=[current] && targetIndex!=null`为0。
- `pageTransition`在9↔10、10↔11边界最密集（65/75），用户在该区域反复双向测试。
- 真正与固定空间位置重复一致的是远端page-host生命周期：page18多次在logicalPosition约10.9~11.0附近mount/dispose；page19也在page11附近短命mount/dispose。
- 全Trace共有111次`pageHostDisposed`；其中8次lifetime<2s，6次集中于page18/19，最短约0.253s/0.281s，且这些短命host均`firstFrameReady=false`。
- page18总计10次mount+10次dispose，后半段出现0.281s、0.660s、1.277s、1.689s、1.878s等短生命周期；这不是可见页面切换，而是ListView cache edge反复穿越。

## 源码归因

`ReaderView`的ListView使用逐步warm到7屏的pixel `cacheExtent`，而`_ReaderPageShellState._keepAliveFor()`只按`abs(page-current)<=7`决定AutomaticKeepAlive。cache/sliver layout先于ScrollNotification，因此outer child进入/离开cache时，shell看到的current可能比该layout落后一页；Trace中同一pageHost甚至会以`keepAlive=true` mount、随后以`keepAlive=false` dispose，证明keepAlive ownership与sliver cache边界缺少滞回。

`_ReaderPageHost`并非纯占位符：mount会构建`LocalImagePlayer`，订阅`PipelinePageStream/PipelinePageOutputStream`，已有surface时构造Texture presentation subtree；频繁cache-edge composition churn即使不产生新decode/upload，也可造成build/layout/compositor尖峰。

## 修复边界

- 不修改current/target/geometry/anchor。
- 不修改Pipeline 3/7、decode/upload、FrameBudget、texture resident reuse。
- page shell本次mount后，在Reader current离mount current不超过2页期间保持composition keepAlive；之后再回归nominal ±7规则。
- 新Trace增加`compositionGuardActive`帮助区分nominal keepAlive与cache-edge guard。

## 下一份Trace判据

重点在同一可复现区域反复上下小幅滑动：page18/page19这类远端host允许首次mount，但不应再在几百毫秒到约2秒内反复dispose/remount；若host churn闭合而仍有固定位置抖动，再下钻Sliver layout/frame timing，不重新打开target或texture假设。
