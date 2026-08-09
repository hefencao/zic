# ADR 0159：Response cancellation 与 Artifact checksum 热路径所有权

状态：Accepted
版本：0.31.0-dev.176

## 背景

dev.175 将 NetLane `TaskControl`贯穿到 Venera request-plan/runtime，并缩短 native WebP decode持有 source读锁的时间。设备 trace随后确认 current 已能进入 `network=5 + reserved=1` handoff，`nativeIngressMicros`也大幅下降；但 origin open仍有约5–19秒长尾，下载期间 artifact commit仍持续占用主 isolate。

代码审计发现两个独立边界遗漏：

1. host `HttpClientResponse` 经过前16字节媒体校验后被 `_PrefetchedHttpResponseBody` 包装。此后 `TaskControl.whenCancelled`不再绑定 body；外层 async* 被取消也没有 `finally`取消底层 iterator。因此 scheduler可以已经宣告 prefetch cancelled，而 socket仍继续接收数据、占连接/带宽。
2. `Artifact._append()` 每个约64KiB commit都在 Dart调用 `Crc32.add()`。5路远端下载会持续在 UI isolate执行逐字节CPU循环；checksum只在 seal/promotion和恢复验证时需要成为权威事实，没有必要在每次partial append同步materialize。

## 决策

- scheduler cancellation必须覆盖 source response完整生命周期：request pending、prefix probe和body streaming。prefetched body注册 `whenCancelled -> abort`，consumer cancellation必须在 wrapper `finally`向底层 response iterator传播。
- cancel仍只是 transport终止请求；NetLane permit只在原 task真实退出后释放，不提前伪造连接空位。
- partial artifact append只负责有序写入与长度推进，不在下载热路径计算CRC。partial snapshot/index在checksum尚未materialize时使用空值表达“未计算”，不得伪造旧CRC。
- `seal()` 在文件writer关闭后重新读取partial文件并在 isolate计算CRC32，再执行 expected checksum验证、metadata seal和promotion。restore/repair同样使用该隔离rehash路径。
- 不通过缩小encoded窗口、降低network并发或放弃checksum完整性换取性能。

## 后果

- 被 current抢占的prefetch不会继续偷偷消耗socket/bandwidth，current的host open不再等待逻辑上已经cancelled的response自然结束。
- 主 isolate不再每64KiB执行一次纯Dart CRC循环；artifact文件I/O仍异步，checksum CPU成本移动到非交互式seal/restore边界。
- 下一次设备trace若仍有current open长尾，应继续区分服务器首包/连接建立，而不是返回NetLane；若仍有下载卡顿，应继续从剩余artifact I/O或通知密度取证。
