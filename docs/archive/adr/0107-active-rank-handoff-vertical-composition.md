# ADR 0107：Active Rank Handoff 与纵向页面预组合

**状态：Provisional**

## 问题

网络 lane 只排序 queued task。同一页从 near 晋升 current 后，active 下载仍保留旧 rank；槽位已满时，新 current 只能等待旧传输自然完成。dev.122 的 active-transfer retention 因而可能反向饿死 current。

纵向 Reader 已局部化 controller rebuild，但 lazy child 首次进入 cache extent 时仍需重新创建完整 page shell，且滚动 observation/命令重复构造页面 extent 前缀。低性能设备的 build+layout 仍可能形成明显尖峰。

## 决策

1. `NetLane` 同时保存 queued 与 active priority；同 key 再提交只迁移 rank，不取消或重建传输。
2. current 阈值为 1000。lane 或同 source bucket 满载时，请求取消最低 rank 且可抢占的 active task，并允许唯一临时 handoff slot。
3. handoff 严格有界：全局和 bucket 均最多临时超过稳定上限 1；旧任务在异步清理完成前继续占有原 permit。
4. active transfer 离开 7/3 窗口时继续完成，但 rank 降为 retained-background=0，不能保留旧 current 优先级。
5. 被抢占但仍有 demand 的 transfer 在清理后重新排队，复用现有 DownloadSession/partial，不建立第二 writer。
6. 纵向 Reader 预创建稳定 page-shell Widget 描述，但不预创建图片、frame 或 texture。
7. `ReaderVerticalGeometry` 作为不可变布局快照，一次计算 extents 与 prefix starts；滚动定位使用 O(1) bounds 和二分查找。
8. 纵向轻量 host cache 在空闲 post-frame 中从 2 屏逐步扩展到 7 屏，分散 element/layout 创建，不在单帧一次建立全部窗口。

## 所有权

- rank migration、抢占、handoff 与 permit：`sessions/NetLane`。
- 页面 rank 与 7/3 demand：`pipeline`/`pipeline_runtime`。
- page-shell composition 与 geometry：`reader`。
- bytes、DownloadSession、decoded frame、texture 与预算：原 owner 不变。

## 拒绝方案

- 缩小 7/3、降低远程并发或取消 retained transfer。
- current 到来时取消并重建同 key 下载。
- Reader 私建图片字节或 decoded-frame 缓存。
- 恢复 visible-page demand 补丁。
- 一次性预创建整章真实图片/纹理。

## 解除 Provisional 条件

设备 Trace 证明 current 提权后立即启动、handoff 最大值不超过 1、同 key transfer 不重开；纵向性能数据证明 cache 窗口内页面首次 build/layout 尖峰下降，且滚动位置与页面 identity 稳定。
