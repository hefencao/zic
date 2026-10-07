# ADR 0095：缓冲帧连续性与启动近邻压力

**状态：Superseded**

启动 priority floor 与 c=8 释放条件由 ADR 0096 取代。缓冲 successor 连续播放与有界 decode recovery 决策继续有效。

## 问题

dev.110 设备 Trace 显示：

1. current 首帧已经完成 Android platform presentation，但 startup foreground pressure 仍允许所有 background priority 的 artifact 流按 chunk 轮转。远端 7/3 窗口的 priority 400 文件会与页面 Surface 发布争用 Dart 事件循环、临时 artifact 写入和 source ingress。
2. 切页后的新 current 已建立 8 帧水位；一次后续 decode failure 使 DecodeSession 进入 failed。FrameHolder 仍有有效 successor，但 UploadSession 在检查 holder 之前直接停止消费，最终停在已呈现帧。

## 决策

- 7/3 demand 与 c/n/m/p 水位不变。显式 startup pressure 期间，artifact scheduler 只允许 priority 不低于 680 的 n/m/p 近邻读取；far artifact 保持 queued，pressure 释放后自动继续。通用 scheduler 只接收阈值参数，680 由 Pipeline composition 注入。
- startup pressure 只有在 current output 已呈现且 c 水位达到 8、或媒体终止/失败时释放。
- DecodeSession failure 不处置 FrameHolder。UploadSession 在 holder 非空时继续消费已解码 successor，保持 output 和 playback 连续。
- current/transition decode failure 触发最多四次、16 ms 递增的有界恢复。恢复任务绑定 demand revision；页面切换后自动失效。
- 同一 cursor 成功产生下一帧即清除恢复状态。若缓冲耗尽且仍失败，下一次 fill 才重建 cursor；可见 output 在此期间保持。

## 所有权

- startup 可读取角色由 `pipeline_runtime` composition 决定；`downloads` scheduler 只执行通用 priority floor。
- cursor failure、FrameHolder 与重试属于 `sessions`。
- Reader/App 不读取恢复计数，不建立第二条 retry 路径。

## 拒绝方案

- 缩小 7/3 下载窗口或关闭 n/m/p 预解码。
- decode failure 时立即清空 holder 或释放可见 output。
- 无限即时重试同一 cursor。
- 在 Widget 层用定时器重新打开页面。

## 解除 Provisional 条件

设备 Trace 证明 startup 期间 far priority 流未获得 chunk；首 Surface 发布延迟下降；`decode-recovery` 在 current failure 后出现；buffered successor 继续呈现；切页后不再停在一两帧。
