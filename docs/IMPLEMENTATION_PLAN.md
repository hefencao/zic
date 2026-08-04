# zic Implementation Plan

本文件只列未完成工作。

## P0：运行时 WebP 分类设备闭环

- 在纵向 Venera 静态 WebP 章节确认出现 `mediaClassified animated=false`；
- 确认两页静态后 `assumeUnresolvedStatic=true`，邻页出现 static-warm decode/upload；
- 验证邻页在成为 current 前得到首帧，且真实动画 WebP 仍维持 staged 水位；
- 若 frameCount/complete 仍无法区分，扩展 native animation metadata，不以扩展名替代。

## P0：纵向轻量 Host 与 Output 生命周期

- 确认 current±4 host Trace 为 `keepAlive=true`，轻微反向滑动不 dispose/remount；
-若仍有顶部重载，区分 output FrameBudget eviction、Surface lease 替换和 source failure；
-禁止 Widget 持有 frame、texture 或 cache body。

## P0：空 Artifact 自愈工具链闭环

- 运行 Flutter analyzer/tests，确认 backend 必需 invalidation 接口全部实现；
-在有历史毒化条目的设备确认自动失效、回源和首帧；
-若出现非零但无效正文，增加 header/error-body 分类。

## P0：剩余加载性能

继续比较 direct ingress、texture reuse、outputPrepare 与 mount-to-first-frame，分别评估静态和动画章节。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
