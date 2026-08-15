# dev.285 固定区域抖动 / promoted physical retention 审计

## 设备事实

输入：`zic-debug-trace-2026-08-14T16-22-43.jsonl`（dev.284）。用户确认固定区域抖动未解决。

- dev.284 guard 的机械目标已达成：此前 page18/page19 在约0.25~2秒内反复 mount/dispose 的 cache-edge churn 不再出现；page18/page19 本轮可持续数十秒到 Reader close。因此 UI composition churn 与用户可见抖动不是同一根因，dev.284 production guard应回滚。
- dev.283 target authority继续闭合；dev.282 `platformResidentReuse`仍大量命中，重复 RGBA Surface copy不是本轮固定位置抖动的主因。
- `composition-physical-retention` 在约41.7秒内记录84次 `retired-promoted-resident`。8.907s、25.830s、30.713s、34.158s、35.757s、36.956s、38.764s、39.837s均出现约5-session连续 retirement burst。
- 25.830s代表窗口中，5个idle promoted session在约1.2ms内由`retainedIdleSessions=4→0`全部退休；随后新的边界需求重新进行local prepare / persistent artifact session-copy。
- persistent artifact的`consumer=session-copy`重复出现；单一identity在本Trace可出现多次完整读取。该模式与dev.269审计留下的“promoted resident idle后立即settle/retire，下一demand再从durable cache重建Reader可消费source”候选完全一致。

## 源码归因

`PhysicalTransferRetention._retireIdlePromoted()`每次maintenance枚举全部`state=promoted && idle` session，并逐个`settleAutomatic → retireIdlePhysical`直到候选清空。它没有 promoted hot budget，因此Reader logical 3/7窗口每次移动都可能把刚离开的immutable physical generation全部销毁。

反向跨回边界后，`DownloadTransferOwner`必须重新创建physical session；persistent artifact虽可避免网络，却仍要通过`artifact-cache-stream`把完整body复制进fresh resident `DownloadSession`。Reader-local sealed ingress可能由dev.279保留，但physical local prepare/session-copy I/O和大量session/source lifecycle事件仍在页面边界重复发生。

## dev.285 收口

- 回滚dev.284 mount-travel composition guard；保留nominal Reader keepAlive逻辑。
- promoted physical retention改为composition-owned LRU，默认最多8个idle promoted sessions。
- 预算内不退休；超预算只退休oldest pressure victim，并保持ordinary artifact handoff成功是退休前置条件。
- partial的32-session/256MiB pressure policy不变，Reader 3/7、NetLane、decode/upload/texture均不改。

## 下一份Trace判据

同一区域反复上下滑时，优先统计`composition-physical-retention`与`artifact-cache-stream consumer=session-copy`：普通边界不应再清空所有idle promoted session；只有超过8个时才有带`reason=hot-promoted-retention-pressure`的retire。若这两项显著收敛但画面仍抖，再下钻Sliver/layout/compositor，不恢复dev.284 UI guard。
