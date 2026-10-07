# dev.112 页面下载排序与 WebP 前缀审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.111_buffered-decode-recovery-startup-pressure.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-04T00-12-47.jsonl`。

## Trace 事实

- 578 条 `framePipelineTiming` 全部走 Android platform presentation。
- persistent source read 最大并发为 5，但旧实现只在内层 artifact chunk 生效；source scheduler wait p95 约 5.31 秒，最大约 8.59 秒。
- far 页面大量共享 priority 400，退出 demand 后仍可在尾部记录 priority 0 的长流。
- 14 次 decode task failure 中，多数 identity 最近一次成功帧来自 `sourceSealed=true` 的完整文件；因此 chunk 不足不是主要通用解释。
- 当前 native ABI 将 sealed WebP 的多类 demux、geometry、libwebp decode 错误合并为 generic failed；本轮不虚构更细根因。

## 修改

| 问题 | 所有者 | 修改 |
|---|---|---|
| 跨 Reader 总并发 | `pipeline_runtime` + `sessions` | composition shared NetLane，全局 5 槽 |
| 不同页同 rank | `pipeline` | 11 页窗口唯一 priority |
| 来源线程上限 | `pipeline_runtime` | local bucket / remote sourceId bucket，当前上限 5 |
| 旧窗口任务残留 | `sessions` | session-scoped task key，removed 时取消 active+queued |
| startup floor 误用 | `downloads` / `pipeline_runtime` | 删除 floor，pressure 恢复 `c>4` |
| partial 重复解码 | `sessions` | 每 key/frame 自适应前缀 |
| failure 语义混淆 | `sessions` / telemetry | source length、sealed、required prefix、failure class |

## 保持不变

7/3、staged c/n/m/p/l、5/3/2 decode/upload lane、last keep、两个常驻 Dart decode isolate、libwebp 帧内单线程与 Android texture 所有权均不变。

## 未验证

当前环境未运行 Flutter/Dart tests、Android native/APK 或 dev.112 真机 Trace。
