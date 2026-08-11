# ADR 0197：Exact DownloadId 的 Composition Physical Transfer Owner

- Status: Accepted
- Date: 2026-08-11
- Version: 0.31.0-dev.216

## 背景

dev.214 已建立scope-based demand claims，dev.215又把Reader-native `Ingress`拆成每个consumer自己的projection，
但生产代码仍由每个 `PipelineReaderSession` 创建 `DownloadRegistry`，并由自己的 `LiveCoordinator`持有
network task、retry/terminal/defer与Reader临时workspace。此时两个Reader即使请求相同exact `DownloadId`，
仍可能各自创建session/writer/network request；反过来若只共享registry，一个Reader dispose又会关闭
另一个Reader依赖的physical task、partial workspace或handoff。

## 决策

1. 新增composition-owned `DownloadTransferOwner`，唯一拥有exact `DownloadId`的physical scheduling：
   `DownloadRegistry`、network task key、retry/terminal/defer、active writer与scoped claims。
2. `_PipelineDownloadTransferRuntime`同时拥有transfer workspace、artifact/partial handoff与physical registry；
   `PipelineReaderSession`只attach `DownloadTransferConsumer`，继续拥有自己的ingress projection、decode/upload与presentation。
3. 所有 `PipelineReaderSessionFactory.withX()` clone共享一个transfer-runtime pool。runtime key按真正durable/physical
   owner identity组成：artifact cache manager、partial store和shared `NetLane`；loader/UA/Reader transport不参与key，
   它们只作为consumer transport provider。
4. 同一runtime key下相同exact `DownloadId`只能存在一个session、一个active run和一个NetLane task。
   provider按最高claim priority选择；相同priority按更早claim稳定选择，不把多个claim求和。
5. Reader/provider退出先撤销自己的claim，并取消/等待已经捕获其transport context的physical task实际退出；
   若仍有其它claim，同一session保留，由剩余provider重新调度，禁止创建第二writer。
6. 最后claim消失时，如果active writer仍在运行，可降为短时retained background；writer真正退出且仍无人需求后，
   physical owner负责通过 `PartialDownloadHandoff`持久化committed partial，再清理tracking。不能等待某个Reader dispose
   或实际上未发生的app-global runtime dispose才保存partial。
7. dev.216只合并**exact `DownloadId`**。verified version/page equivalence仍停留在immutable artifact reuse层；
   下一阶段必须先把source-confirmed relation、persisted verified mapping、strong media identity组成verified TransferKey，
   再在physical acquire之前归一。标题、页码、相似URL等弱证据继续禁止。
8. chapter/whole-comic/prefetch尚未全部改成shared owner claims；旧handoff/takeover路径继续作为兼容层，
   只有新路径覆盖并验证冷/热生命周期后才能删除。

## 生命周期

```text
PipelineReaderSession A ─ claim + transport A ─┐
                                               ├─ DownloadTransferOwner
PipelineReaderSession B ─ claim + transport B ─┘    ├─ exact DownloadSession
                                                    ├─ one writer / one task
                                                    ├─ retry / terminal / defer
                                                    └─ partial final drain

Reader A -> IngressProjection A -> Decode/Upload A
Reader B -> IngressProjection B -> Decode/Upload B
```

`DownloadTransferOwner`共享physical transfer，不共享Reader native source、cursor、texture或presentation。

## 后果

正面：同一exact资源不再因Reader/factory clone重复产生physical owner；logical cancel与transport关闭分离；
最后consumer退出不会丢失committed partial；retry/terminal state不再有多个Reader owner。

代价：runtime pool成为composition生命周期对象，需要显式idle/all dispose；consumer transport provider切换必须等待旧task
真正退出；verified跨版本hot sharing、chapter/whole-comic聚合仍未完成，因此不能提前删除dev.205–213兼容机制。
