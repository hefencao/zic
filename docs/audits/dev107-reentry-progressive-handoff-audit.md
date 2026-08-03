# dev.107 Reader 重进与 progressive artifact handoff 审计

## 输入证据

- 基线：`zic_v0.31.0-dev.106_startup-foreground-pressure-whole-body-ingress.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-03T13-26-58.jsonl`。
- 编译报告：`错误报告(53).txt`。

## 问题清单

### 编译

- `ArtifactCacheReadScheduler?` 在 Trace closure 中被直接解引用。修复为 nullable-safe projection，未改变 scheduler 行为。

### 产品 / 性能

- Reader 1 dispose 开始后约 0.39 秒 Reader 2 已建立，但 Reader 1 总 dispose 约 10.4 秒，覆盖 Reader 2 的整个主要使用区间。
- handoff 对 ephemeral promoted session 先完整 materialize，再由持久 store 判断是否已经存在相同 artifact；cache-hit Reader 因此制造无意义读回。
- Reader 2 current 的 18,319,682-byte whole-body append 单次 native ingress 约 0.68 秒、临时 artifact 写入约 1.12 秒；source-ready 被整块消费阻塞。
- 整文件 materialize 本身约 36 ms，不是该样本的主要瓶颈。

## 所有权表

| 问题 | 所有者 | 修改 |
|---|---|---|
| 已存在 artifact 重复 materialize | `downloads` | presence capability + handoff skip |
| whole-body 阻塞 source-ready | `downloads` | startup-segmented response |
| dispose 阶段不可区分 | `pipeline_runtime` | 分阶段 lifecycle Trace |
| nullable Trace projection | `downloads` | `?.` + 默认值 |

## 保持不变

- 下载 7/3、预解码 2/1、upload current/transition、lane 5/3/2。
- 两个常驻 Dart decode isolate、libwebp 帧内单线程、current 两个 successor。
- Reader/App 不拥有 artifact cache、scheduler、transport 或 mutable session。

## 未验证

设备尚未运行 dev.107；不能把重进和前帧改善写成已验证事实。
