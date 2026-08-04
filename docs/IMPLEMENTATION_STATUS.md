# zic Implementation Status

**源码版本：** `0.31.0-dev.117`  
**App build：** `0.31.0+117`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3、composition 全局 5 槽、页面 rank 与来源 bucket。
- 动画 staged c/n/m/p 为 8/6/4/3；last 暂停并保留 output。
- `targetWatermark=1` 的静态/未分类页面先通过 `one>0` 单帧 bootstrap，再进入媒体权威分类。
- 本地 WebP 初始作为潜在动画候选；decoder 完整 metadata 覆盖来源 hint。
- DecodeSession 在第一帧后即可上报完整 animation metadata，不必等待 cursor end。
- 纵向 Reader 按真实视口交叠建立 transition，current±4 保留轻量 host。
- 静态页使用 96 MiB 预热选择和 128 MiB output budget。
- durable cache direct ingress、空 artifact 自愈、texture pool 与事件驱动 waitingSource 保持。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.117 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK | Unverified：当前环境无 toolchain |
| 动态 WebP bootstrap 与纵向静态邻页预热 | Unverified-device |
