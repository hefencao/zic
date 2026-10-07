# dev.111 前帧与切页停滞审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.110_staged-waterline-last-frame-first-surface.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-03T23-30-14.jsonl`。
- 用户标注：开头为进入 Reader 的前几帧卡顿；末尾为切页后播放一两帧停滞。

## Trace 结论

### 开头

- native texture 主路径正常，全部 timing 为 platform。
- mount 后 frame 0 约 0.42 秒完成 platform presentation，但页面 first-ready 约 0.82 秒。
- startup pressure 期间 priority 720/700/680 的近邻和 priority 400 的 far artifact 都获得 chunk；两条约 20 MiB far stream 的首 chunk 等待约 0.4–0.5 秒，完整 session-copy 约 1.68 秒。
- 因此首帧后卡顿不是 build/layout/paint/raster，也不是 native texture fallback，而是 startup 阶段 far artifact 与 current Surface 发布、session-copy 和 decode dispatch 并行。

### 末尾

- 页面 9 成为 current 后已有 depth 8；frame 0、3、4、5、6、7、8 均完成 platform presentation。
- refill 后出现 `Failure(decode): frame decode failed`，DecodeSession 为 failed，但 holder 仍有 depth 8。
- playback timer 随后记录 `successorBuffered=true`；UploadSession 却因 failed 状态拒绝消费 holder，之后没有新 frame timing，表现为播放一两帧后停滞。

## 修改

- startup external pressure 增加 composition-provided priority floor 680；far artifact 仍在原 7/3 plan 中，但不在首水位阶段读盘。
- pressure 释放条件从 output + c>3 提升为 output + c>7。
- DecodeSession failure 保留 holder 与 cursor retry 意图；状态内聚为 `restartCursorWhenHolderEmpty`，成功 successor 清除重启标记。
- UploadSession 仅在 failed 且 holder 为空时投影失败；holder 非空时继续按 deadline 消费。
- LiveCoordinator 对 current/transition 做 revision-bound、最多四次的有界 decode recovery。
- analyzer 增加 decode recovery 数量、attempt 和 buffered depth。

## 未验证

当前环境没有 Flutter/Android 设备工具链；dev.111 的首帧和切页恢复尚未真机复验。
