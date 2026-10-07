# dev.201：restart-cost retention 根因与方案审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.200_deferred-catchup-memory-two-tier-cost.zip`。

## 根因

dev.199/200 已经把“是否值得启动不可Range full-body catch-up”建模为成本 admission，但 NetLane 的 victim selection 仍只按 active task 的 base demand priority。于是已经投入很长 wall time / 数 MiB full-body 数据的低priority catch-up，仍可能比刚启动、取消几乎无重做代价的稍高priority transfer更早被杀。

真正要保护的不是“慢CDN”或一般历史投入，而是取消后会重新支付的工作：

- full-body catch-up 从byte0开始且服务器不支持可证明Range continuity时，当前response已消费bytes在下次需要时会重新传输；
- request-plan/host-open/body receive已经花掉的attempt wall time也会重做；
- 普通可resume Range的committed bytes已经成为artifact authority，不因总下载时间长获得该bonus。

## dev.201 选择

- DownloadJob只在full-body catch-up通过admission后调用`beginRestartCost()`，并随response消费更新累计restart-cost bytes。
- task激活时间由NetLane的CancelToken记录；确认full-body后把“激活至当前”的已付时间纳入成本，因此慢request-plan/host-open不会被漏掉，queue wait不计入。
- NetLane独占rank公式：时间5s尺度/最多60，流量4MiB尺度/最多40，均使用指数饱和；不把网速先换算为policy输入。
- retention只参与victim selection；pending顺序、priority migration、current handoff不改变。
- current-safe cap保证1000相对任意retained lower task仍至少有40点margin。
- 新`downloadPreempted` Trace仅用于验证实际victim选择，记录base/retention rank与付出成本，不参与反馈调度。

## 需真机验证

1. high-cost full-body attempt与cheap普通transfer同时active时，transition/pressure应优先取消cheap victim；
2. current=1000在所有victim都有高restart cost时仍能及时物理preempt；
3. `downloadPreempted`中restartCostElapsedMicros/restartCostBytes应仅在full-body不可恢复attempt上非零；
4. 观察重复流量、attempt completion率、current startup，防止retention导致慢旧任务长期占满5个slot。
