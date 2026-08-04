# zic Implementation Status

**源码版本：** `0.31.0-dev.122`  
**App build：** `0.31.0+122`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3；全局与远程 source bucket 为 5，本地只读 source bucket 为 2。
- `content/file/asset` 完整只读响应通过权威 DownloadSession 直连 sealed ingress，不写 Reader 临时 artifact，也不显示网络下载进度。
- 动画 staged c/n/m/p 为 7/5/3/2；last 暂停并保留 output。
- 权威静态页只要 holder 或 output 已有一帧，就视为现有 demand 水位已满足；混合章节不拆分 refill 状态机。
- `targetWatermark=1` 页面通过 `one>0` bootstrap；source revision 为对应 DecodeId 定向执行 staged refill。
- 未封缄 WebP 已连续证明至少 30 帧可解码后，可在当前 prefix 内循环播放；source 下载和前缀扩展继续后台推进。
- 已开始的 partial transfer 离开窗口后继续完成；只取消尚未开始的 queued task。promoted、active、queued 或 retry-pending session 不重复提交。
- 远程传输单轮重试耗尽后使用跨 observation revision 的 session 级有界退避；source 字节增长会重置连续失败状态。
- 静态 output 失去 upload demand 后可在无需求状态驻留；实际超出 128 MiB output budget 时由 FrameBudget 回收。
- Reader current/stable 变化只更新状态实际变化的页面 shell；页面 runtime ratio 只驱动 ReaderView 局部更新，已有源尺寸时忽略小于 1% 的舍入差异。
- 纵向 anchor 修正忽略小于 2 logical px 的微调；durable cache direct ingress、空 artifact 自愈与 texture pool 保持。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.122 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK | Unverified：当前环境无 toolchain |
| 7/5/3/2、30 帧前缀循环、下载保留/退避与纵向滚动稳定性 | Unverified-device |
