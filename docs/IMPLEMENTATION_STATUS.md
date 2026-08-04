# zic Implementation Status

**源码版本：** `0.31.0-dev.118`  
**App build：** `0.31.0+118`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3；全局与远程 source bucket 为 5，本地只读 source bucket 为 2。
- `content/file/asset` 完整只读响应通过权威 DownloadSession 直连 sealed ingress，不写 Reader 临时 artifact，也不显示网络下载进度。
- 动画 staged c/n/m/p 为 8/6/4/3；last 暂停并保留 output。
- `targetWatermark=1` 页面通过 `one>0` bootstrap，decoder 权威分类覆盖来源 hint。
- 纵向 Reader 上报全部真实可见页；current、transition、visible、last output 均受 FrameBudget 保护。
- 静态页按实际页面尺寸使用 96 MiB 预热选择，128 MiB output budget 仍为实际裁决。
- durable cache direct ingress、空 artifact 自愈、texture pool 与事件驱动 waitingSource 保持。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.118 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK | Unverified：当前环境无 toolchain |
| 本地 direct ingress 与纵向全部可见 output | Unverified-device |
