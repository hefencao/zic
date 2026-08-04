# dev.113 持久缓存直连与 Texture Pool 审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.112_ranked-download-adaptive-webp-prefix.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-04T01-15-34.jsonl`。

## Trace 结论

- 171 条逐帧 timing 全部使用 platform presentation；task failure 为 0，global page download active 最大为 5。
- 三次初始页面 mount-to-first-frame 约为 1.03 秒、1.91 秒和 1.63 秒。
- 三个 current frame 0 的 `outputPrepareMicros` 约为 154 ms、1067 ms、618 ms；后两次主要长尾不在文件 materialize 或 native decode。
- source read 共 30 条，stream p95 约 3.59 秒，scheduler wait p95 约 2.04 秒；其中 cache-hit 页面仍完整进入 session-copy。
- 171 条逐帧 timing 对应 246 次 `decodeRefill`，存在 waitingSource 无新字节时的重复协调工作。

## 修改与所有权

| 问题 | 所有者 | 修改 |
|---|---|---|
| durable cache 命中重复写临时文件 | `transport` + `downloads` + `sessions` | disposition + resident ingress |
| memory tier durability 丢失 | `downloads` | key+length durable projection |
| Reader 重进重建 texture | `pipeline_native` | composition lease pool |
| output 创建串行阻塞 frame 0 | `pipeline_runtime` | PageAsset 尺寸预热 |
| waitingSource 重复入队 | `sessions` | source-revision wake gate |

## 生命周期检查

- durable cache body 仍由 `DownloadJob` 注入权威 `DownloadSession.ingress`；没有新增 decoder cache reader。
- resident ingress 不获得 writer，不调用 `Artifact.appendOwned`，不生成新的 partial/final 文件。
- resident stream failure 会取消 iterator 并 reset session，不能遗留 receiving 状态。
- texture pool 位于 factory composition，不属于 Reader widget；session close 归还 lease，last output 的 present claim 仍可阻止过早回收。
-预热尺寸集合去重；失败会清除标记并允许后续 lazy create。

## 保持不变

- 页面下载 7/3、全局并发 5、来源 bucket 与页面 rank。
- staged c/n/m/p 上限 8/6/4/3，last keep。
- decode/upload lane 3/2、两个常驻 decode isolate、libwebp 帧内单线程。
- origin/partial/resume 仍写 artifact，durable backend 仍是唯一持久副本。

## 未验证

当前环境无 Flutter/Android/Rust 完整工具链与设备，不能把 dev.113 的首帧改善、texture reuse 或 resident ingress 性能写成设备事实。
