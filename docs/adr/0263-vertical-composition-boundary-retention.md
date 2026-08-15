# ADR 0263：纵向 composition cache 边界滞回

状态：Superseded

接受版本：dev.284。

由 dev.285 / ADR 0264 取代：16:22 dev.284 真机 Trace 证明该 guard 确实消除了原先 page18/page19 的短命 composition churn，但固定区域画面抖动仍存在，因此该行为已从 production 回滚。保留本文仅作为被设备否证的历史实验记录。

## 背景

15:33 dev.283 真机 Trace 说明 dev.283 的 hidden-target 修复已闭合：`visibleIndexes=[current]` 时 `targetIndex!=null` 的样本为0；dev.282 resident texture reuse也持续真实命中。因此剩余“固定区域上下都抖”不能继续归因到target方向、anchor或重复Surface blit。

Trace 中抖动集中在 page9/10/11 附近，但真正重复翻转的是远离viewport的 ListView composition/cache 边界。page18在 `logicalPosition≈10.995` mount、`≈11.018` dispose；回滑到`≈10.890`再次mount、`≈11.001`再次dispose，后续还在`10.998→11.001`、`10.961→11.000`、`10.977→11.025`重复。page19也出现约0.253s的短命mount/dispose。整份Trace只有8个lifetime<2s的page-host dispose，其中6个是page18/19，且均未产生first frame。

Reader目前同时使用两个不同尺度：ListView以像素`cacheExtent` lazy mount child，`_ReaderPageShell`却按`abs(page-current)<=7`控制AutomaticKeepAlive。sliver layout/eviction先发生，ScrollNotification随后才把新的currentIndex写入ReaderController，因此cache-edge host可能在下一页即将成为keep-alive成员前一帧先被dispose；局部反复上下滑时，同一重型`LocalImagePlayer/pageOutput/Texture`子树被反复创建和销毁。

## 决策

1. Pipeline previous3/next7、decode2/1、holder与texture预算全部保持不变；本ADR只拥有Reader UI composition element生命周期。
2. 既有nominal page-host keep-alive radius仍为7页，不通过扩大Pipeline window或cacheExtent掩盖问题。
3. 每个纵向page shell记录其本次mount时的`currentIndex`。除nominal ±7外，在Reader current尚未离该mount point超过2页时，该host继续保持AutomaticKeepAlive。
4. mount-travel guard按页面位移而非wall-clock timer实现；局部上下反复穿过同一cache边界不会立即销毁刚组成的重型host，持续向远处阅读超过guard后仍可正常淘汰。
5. `pageHostMounted/pageHostDisposed` trace保留既有`keepAlive`并新增`compositionGuardActive`，下一份真机可直接确认cache-edge host是否由guard吸收。
6. dev.280/281 geometry、dev.282 resident reuse、dev.283 vertical visible-target authority继续冻结；当前Trace没有回滚证据。

## 拒绝方案

- 把`cacheExtent`从7屏改到8/9屏：只会把无滞回的composition分界移动到另一个位置。
- 直接扩大download/decode/upload窗口：问题是Widget element churn，不是媒体供给不足。
- timer/grace延迟dispose：设备帧率和手势速度相关，且会形成时间型生命周期owner。
- 永久keepAlive所有访问过的页面：长章节element/Texture widget数量无界。

## 验证

- page18这类cache-edge host在mount时即使尚处nominal ±7之外，只要current尚未离mount point超过2页，`keepAlive=true`且`compositionGuardActive=true`。
- 在同一页边界附近上下反复滑动时，不应再出现同一page host数百毫秒到约2秒内反复mounted/disposed。
- current真正离开mount point超过2页且该页也已超出nominal ±7后，guard必须释放，确保composition retention仍有界。
