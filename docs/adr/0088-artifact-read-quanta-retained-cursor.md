# ADR 0088：Artifact 分块调度与 retained cursor 连续性

- 状态：Provisional
- 日期：2026-08-03

## 背景

dev.103 设备 Trace 显示 Reader 启动阶段 persistent artifact 读取达到共享并发上限。current 与多条 background session-copy 同时完整复制 17–21 MiB 页面，整条 stream 的 lease 在文件结束前不释放。设备表现为前帧和早期切页持续拥堵，等 encoded source 水位完成后才明显变顺。

同一 Trace 还显示页面离开上传窗口后保留 frame 0，但 `DecodeSession.detach()` 仍无条件标记 cursor 重启。页面重新成为 current 并消费 retained frame 后，下一次 fill 会重新创建 cursor，再次产出 frame 0，导致新页只显示首帧而不继续播放。

## 决策

1. persistent artifact scheduler 的公平调度量由整条 stream 改为 chunk quantum。
2. current/transition stream 在保持 foreground 时可连续持有 lease；background 每个 chunk 后释放并重新申请。
3. foreground active 或 pending 时，background 最多同时占用一个 chunk 槽；foreground 压力消失后 background 可使用全部共享容量。
4. 每次 background 申请下一 chunk 时重新读取 Pipeline 权威 priority。background→current 晋升不取消、不重开 stream。
5. `DecodeSession.detach()` 仅在 holder 为空时标记下一次 demand 重建 cursor；若保留 frame，则 cursor 继续前进。
6. output 真正丢失且 holder 为空时，仍由 `prepareForOutputLoss()` 显式请求重播。

## 所有权

- artifact stream 公平性与 lease：`downloads`；
- demand priority：`pipeline_runtime`；
- decode cursor 与 retained frame：`sessions`；
- Reader 只提交 observation，不获得 scheduler 或 cursor 权限。

## 未验证

需要 dev.104 Android 设备 Trace 验证：

- foreground 压力期 background chunk 并发不超过 1；
- current first-chunk/source-wait 和启动帧长尾下降；
- 切到新页后不再重复上传 frame 0；
- 既定 7/3、2/1、current/transition 和 5/3/2 没有退化。
