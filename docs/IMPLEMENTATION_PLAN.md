# zic Implementation Plan

本文件只列未完成工作。

## P0：传输与 Partial WebP 设备闭环

- 确认动画 current/transition/next2/previous 的实际最大水位为 7/5/3/2，权威静态页一帧后不再参与补水；
- 确认未封缄 WebP 达到 30 个已证明可解帧后出现 `animationLoop partialPrefix=true`，并在下载继续增长时稳定循环而非等待 seal；
- 对比 partial prefix 循环前后的播放停顿、循环边界、帧序和 source 增长；
- 确认 active non-resumable transfer 离开窗口后不再收到 cancelled，重新进入时不会从 `rangeStart=0` 重启；
- 确认 promoted、active、queued 与 retry-pending session 不因 policy revision 重复 `downloadStarted`；
- 检查 `download-recovery` 的退避次数、延迟和最终成功/终态，避免网络失败风暴。

## P0：无法加载设备闭环

- 对 10:50 Trace 中失败 identity 复验 session 级退避是否跨 revision 保持；
- 区分 CDN/transport 失败、HTTP 非图片响应、source seal 与 decode failure；
- 若有稳定终态失败，页面应展示可重试错误，而不是无限 loading。

## P0：纵向滚动性能

- 使用 performance overlay/DevTools 比较 PageAsset ratio 更新前后的 build/layout 长尾；
- 确认已有源尺寸时，小于 1% 的 decoder 尺寸舍入不再触发 ReaderView 重建；
- 记录 anchor capture/restore 与实际 jumpTo 修正量，确认小于 2 logical px 的微调被忽略；
- 若仍卡顿，继续审计 item extent 计算、texture upload 和剩余 page-local rebuild，不关闭必要的尺寸更新。

## P0：Flutter 与 Android 工具链

运行 analyzer、owner tests 和 Android debug/release，确认实际编译闭包。

## P1：来源能力配置

在保持全局 5 的前提下，为不同远程漫画源暴露独立 bucket cap；本地并发是否从 2 调整必须以设备吞吐为依据。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
