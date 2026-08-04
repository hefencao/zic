# zic Implementation Status

**源码版本：** `0.31.0-dev.123`  
**App build：** `0.31.0+123`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 下载窗口保持前 7 / 后 3；全局/远程并发 5，本地只读并发 2。
- queued 与 active 下载任务均保存页面 rank；同 key 晋升 current 只迁移 rank，不重建 transfer。
- current 在 lane 或 source bucket 满载时可使用唯一有界 handoff slot，最低 rank active task收到取消请求；临时超额不超过 1。
- 离窗 active transfer 继续完成但降为后台 rank 0；被抢占且仍有 demand 的任务清理后重新排队并复用既有 session/partial。
- 动画 staged c/n/m/p 为 7/5/3/2；静态一帧即满足；partial prefix 30 帧循环与 retained output 保持。
- 纵向 Reader 复用预组合 page-shell Widget；geometry 一次计算 extent/prefix，并以二分定位可见页。
- 轻量 host cache 在空闲帧从 2 屏渐进预热至 7 屏；图片/frame/texture 仍由 Pipeline 与 FrameBudget 管理。
- durable cache、local direct ingress、texture pool、source-wake 与纵向 anchor 阈值保持。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.123 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK | Unverified：当前环境无 toolchain |
| current 抢占与纵向 build/layout 真机效果 | Unverified-device |
