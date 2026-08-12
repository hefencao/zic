# dev.249 根因审计：动画预下载应限body水位而非缩窗口

## 输入
- 唯一代码基线：dev.248完整包。
- 真机Trace：`zic-debug-trace-2026-08-12T14-13-54(1).jsonl`。

## 问题清单
- 产品：2/4 eligibility让动画normal浏览只有7个download demand，弱化了3/7快速翻页准备。
- 性能：Trace共6756事件，13次preempt；动画classification共9次，均为animated，frameCount主要154且有173。浪费主体应从“整页是否下载”改为“远端已打开response允许继续读几帧”。
- 编译：Trace无编译错误证据；当前环境无Dart/Flutter/Cargo。

## 所有权清单
- 3/7页面成员与semantic demand：Pipeline RoleResolver/HeuristicPolicy。
- per-page动画frame credit：Pipeline AnimatedPrefetchPolicy。
- task rank/slot与可变credit投影：NetLane。
- body pause执行与ANMF边界：DownloadJob；只消费transport capability。
- physical writer/partial：DownloadSession，不变。

## 被否决方案
- 继续2/4 eligibility：正常快速浏览退化。
- 继续50MiB estimated whole-body active admission：按未知12MiB估算页面，不直接控制实际已读帧/字节。
- 增加cancel hysteresis：把流量问题再次转成生命周期补丁。
- 本轮直接提高连接数：会同时改变socket pressure与body flow，难以归因；先冻结5+reserved1。

## 决策
恢复完整3/7 demand，以frame credit+真实stream backpressure限制远端动画body。
