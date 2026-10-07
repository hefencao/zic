# ADR 0081：50% 播放所有权交接与有界诊断 Trace

- 状态：接受；第 6 项构建准备机制由 ADR 0082 取代
- 版本：0.31.0-dev.97
- 取代：ADR 0080 中未规定 PageView midpoint 细节的部分

## 背景

设备 Trace 显示，`PageView.onPageChanged` 在 50% 边界先发送整数 observation，短暂移除 outgoing page 的 upload demand，随后 scroll notification 又将其作为 transition 加回。该真实 detach 会退休仍有效的 texture，产生黑屏和重新上传。默认 0.6 dominant threshold 同时让 40%–60% 的两页停止播放。异步创建 UploadSession 还可能错过既有 viewport 的 freeze/resume。

同一 Trace 含 6486 条、约 4.15 MB。事实并非过多，而是高频状态投影重复完整 identity，缺少诊断层摘要。

## 决策

1. Reader 在 `onPageChanged` 中保留 `PageController.page` 的 fractional position。stable page 可改变，但 outgoing page 在仍可见时必须继续作为 target/transition 出现在同一 `ReaderObs`。
2. 离散翻页默认以 0.5 为 dominant threshold。PageView 报告新 stable page 时，精确 50% tie 由新 stable/current 接管；超过 50% 新页继续播放，旧页暂停但保持 transition output。
3. Pipeline runtime 在 UploadSession snapshot 到达时重投影 ReaderBinding 已保存的 viewport，使晚创建的 session 立即获得正确 freeze/resume。它不得创建第二 viewport 状态。
4. Debug Trace 的权威事件继续由原所有者发出。App export projection 可按 kind/session/identity/state 在 250 ms–1 s 的固定首事件窗口内合并高频事件，保留 count、首尾 frame/position/timestamp 和数值 min/max。错误、拒绝、retry 与生命周期边缘不合并。
5. telemetry 对超过 160 字符的 identity 输出稳定 FNV hash 与原长度，不输出完整 locator。该摘要只用于相关性，不替代业务 identity。
6. （已由 ADR 0082 取代）dev.97 曾使用函数锚点 transformer；当前使用锁定离线归档、干净 source hash、零 fuzz patch dry-run 和独立 verifier。

## 后果

- 50% 交接不再产生 targetless demand gap，旧 output 不因翻页边界错误退休。
- current 播放可在稳定页切换时立即接管；transition 继续持有 output 但暂停，不增加 upload window。
- Trace 仍可定位错误和性能范围，同时显著减少文件体积。
- Flutter/Dart、Android 和真机验证仍需有工具链环境执行；静态门禁不能替代这些验证。
