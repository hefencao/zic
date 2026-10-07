# ADR 0066：帧消费推进、源像素合成与诊断聚合

## 状态

Accepted，取代 ADR 0065 中“仅靠 source revision 持续推进动画”的不完整实现。

## 决策

1. source revision 只表示 encoded source 创建、增长、seal 或失败；它只能解除 `needMoreData`，不能代表播放帧消费。
2. `UploadSession` 当前帧到期并释放 output 后，`LiveCoordinator` 必须独立补充 decode watermark。该 decode 不受 source revision gate 限制；只有 snapshot 显示新帧、failure 或终态时才继续唤醒 upload，因此 sealed source 中尚未消费的动画帧可继续播放且不会先提交一次空 upload。
3. `DecodeRegistry.fill` 返回 `DecodeSnapshot`。Coordinator 只有在 holder 深度增加、failure 改变或到达终态时才唤醒 upload；holder 已满的 source chunk 不产生 decode/upload 空转。
4. production source wake 以首次 ready、每 64 KiB 增长、seal 和 failure 为边界；不改变下载窗口或网络 lane。
5. Animated WebP 的 blend/dispose 必须先在源 canvas 像素网格完成，再将完整 canvas 等比缩放到统一的 8 像素输出栅格。禁止独立缩放动画 sub-rect 后再拼接。
6. `DownloadSession` 将小网络 chunk 的 `bytesCommitted` telemetry 聚合为至少 64 KiB 或终态尾包摘要，保留累计长度和 chunk 数。Debug raw ring 默认上限降至 10000；错误和终态事件不合并。
7. 流式测试必须显式 drain/cancel 后等待 controller close；几何 double 使用有界容差。不得用真实 socket、固定等待或精确二进制浮点相等。

## 后果

- 下载完成后动画不再因 source revision 静止而停在最后一个已解码帧。
- 小 chunk 不再制造成千上万次无效 decode/upload 与 Trace 记录。
- horizontal-strip 动画以源像素语义合成，不受 sub-rect 缩放舍入影响。
- 诊断导出更小，同时仍能恢复累计字节、chunk 数、错误和终态。
