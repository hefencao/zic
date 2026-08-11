# dev.216 Composition Physical Transfer Owner 根因审计

## 唯一基线与迁移问题

唯一源码基线：`zic_v0.31.0-dev.215_reader-local-ingress-projection-split.zip`。dev.215已经证明一个physical
`DownloadSession`可以安全投影给多个Reader-local ingress，但生产composition仍是一Reader一registry/coordinator。
因此剩余重复下载的owner根因不是projection，而是physical scheduling与lifecycle仍跟Reader会话绑定。

## 为什么不能只共享 DownloadRegistry

`LiveCoordinator`在dev.215仍持有network task key、retry round/pending、terminal failure、deferred catch-up；
Reader dispose又会drain partial/artifact、dispose registry/workspace。只把`DownloadRegistry`放进Factory会形成：

- A/B coordinator同时调度同一个session，产生双retry/双task owner；
- A退出可能dispose B仍在消费的registry/workspace；
- active task已经捕获A的transport context时，A若立即关闭transport会破坏B后续共享transfer；
- 最后Reader退出后composition runtime仍存在，若只在runtime最终dispose时保存partial，冷启动durable reuse会退化。

## dev.216 最小完整迁移边界

- `DownloadTransferOwner`接管physical task/retry/terminal/defer/claim scheduling。
- `_PipelineDownloadTransferRuntime`接管registry、workspace、artifact handoff、partial handoff与promotion listener。
- 所有Factory clone共享runtime pool；key只使用artifact cache manager、partial store和shared NetLane identity，
  不把loader/UA这种consumer context伪装成physical identity。
- `LiveCoordinator`降级为Reader demand/decode/upload coordinator，physical refresh/retry全部委派。
- provider Reader dispose先取消并等待捕获该provider的task，再允许关闭Reader transport；剩余claim重新选择provider，
  session/artifact/writer identity不变。
- final unclaimed partial由physical owner在writer退出后立即drain到现有`PartialDownloadStore` owner；
  promoted immutable artifact仍只归`ArtifactCacheManager`，不建立第二durable cache。

## 行为可识别性

新增Dart行为测试区分三个问题：

1. A active、B加入相同exact id：registry只有一个session、一次transport open、一个writer；
2. A为active provider后退出：A task先物理退出，B的700 claim与同一session保留，B只重新open一次完成；
3. 最后consumer退出但已有committed prefix：writer退出后physical owner只drain一次，持久化长度等于committed length。

当前环境没有Dart/Flutter，因此这些测试属于已新增/静态审查但未执行；不能把Python gate当成Dart test。

## 仍保留的补偿路径

- verified artifact equivalence / persisted page mapping：保留，下一阶段作为TransferKey proof输入；
- durable partial reuse：保留，负责进程/冷启动边界；
- equivalent-full promotion takeover：兼容层；verified TransferKey前移覆盖后再评估删除；
- session partial handoff：其“Reader owner”语义已被composition physical owner取代，但durable handoff能力继续保留；
- retained Reader session：继续只为Source/Decode/media等Reader-local资源服务，不再是physical download唯一owner。

## 下一阶段

先实现verified TransferKey-before-acquire，只接受source-confirmed relation + persisted verified page mapping + strong media
identity等现有强证据，使old/page/X与new/page/Y在physical session建立**之前**合流。之后再把prefetch、单章、整本
下载改成统一claims。未覆盖前不删除late takeover/durable partial兼容链。
