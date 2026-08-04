# zic Implementation Plan

本文件只列未完成工作。

## P0：空 Artifact 自愈设备闭环

- 使用已有毒化缓存进入 Reader，确认首次 lookup 清除 L1/L2 后自动回源；
- 确认 Trace 不再出现 0 字节 cache hit、`artifactPromoted length=0` 或 handoff `stored bytes=0`；
- 验证本地、Venera、Mihon 页面均不会因空响应永久进入 FormatException；
- 若仍有非零但无效正文，补充 header/error-body 分类，不能用 decoder retry 掩盖。

## P0：纵向静态 Host 与 Output 生命周期

- 向上/向下小幅反向拖动，确认 current±4 静态 host 不 dispose/remount；
- 比较 pageHost mount/dispose、firstFrameReady、last/previous output 与 FrameBudget 回收；
- 若顶部仍短暂重载，区分 host remount 与 output budget eviction，禁止 Widget 建第二套图片缓存。

## P0：剩余首次加载长尾

继续比较 direct ingress、texture reuse、outputPrepare 与 mount-to-first-frame，分别评估静态和动画章节。

## P0：工具链闭包

运行 Flutter analyzer/tests、Android native/APK debug/release 和 Rust tests。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 owner harness。
