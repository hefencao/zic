# zic Implementation Status

**源码版本：** `0.31.0-dev.121`  
**App build：** `0.31.0+121`

本文件只描述当前源码快照和验证等级。历史见 `CHANGELOG.md`，单轮证据见 `docs/audits/`。

验证等级：`Implemented`、`Verified-static`、`Verified-toolchain`、`Verified-device`、`Unverified`。

## 当前实现

- 页面下载保持前 7 / 后 3；全局与远程 source bucket 为 5，本地只读 source bucket 为 2。
- `content/file/asset` 完整只读响应通过权威 DownloadSession 直连 sealed ingress，不写 Reader 临时 artifact，也不显示网络下载进度。
- 动画 staged c/n/m/p 为 8/6/4/3；last 暂停并保留 output。
- `targetWatermark=1` 页面通过 `one>0` bootstrap，decoder 权威分类覆盖来源 hint。
- source revision 只有在对应 decode fill 实际消费后才记账；未消费 revision 会为对应 DecodeId 建立定向 staged refill，不再被其他页面的全局 refill 重定向。
- 权威静态页只要 holder 或 output 已有一帧，就视为现有 demand 水位已满足；混合章节不拆分 refill 状态机。
- 静态 output 失去 upload demand 后可在无需求状态驻留；实际超出 128 MiB output budget 时由 FrameBudget 回收。
- 纵向轻量 host 使用七页保留半径；静态预热仍按实际页面尺寸使用 96 MiB 选择预算。
- Reader current/stable 变化只更新状态实际变化的已挂载页面 shell；ReaderView 和整个 Scaffold 不再随每次页进度通知整体重建。
- durable cache direct ingress、空 artifact 自愈与 texture pool 保持。

以上为 Implemented；真机效果不能由静态源码推导。

## 验证矩阵

| 检查 | 状态 |
|---|---|
| repository/documentation/Dart/Kotlin static gates | Verified-static |
| dev.75–dev.121 ownership 与平台合同 | Verified-static |
| pinned libwebp host build/smoke | Verified-toolchain |
| Flutter analyzer/tests | Unverified：当前环境无 SDK |
| Android APK | Unverified：当前环境无 toolchain |
| 静态单帧水位、定向 source-wake、纵向滚动稳定性与局部 rebuild | Unverified-device |
