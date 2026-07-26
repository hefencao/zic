# zic Project Charter

## 1. 项目定义

`zic` 是一个面向移动设备的高性能漫画阅读器。它优先解决以下问题：

1. 当前页必须优先下载、解码和显示，任何邻页工作都不能阻塞当前页。
2. Animated WebP 应尽可能在文件下载完成前开始播放。
3. 翻页前后的下载、缓存、解码和上传水位应由资源策略统一管理。
4. 策略可根据用户行为、漫画元数据、网络和设备状态逐步个性化。
5. 个性化必须受硬性资源约束保护，不能引发 OOM、热失控、流量失控或当前页饥饿。

## 2. 产品愿景

用户打开漫画后，应感受到：

- 当前页优先出现；
- 连续阅读时下一页几乎不等待；
- 快速回看时上一页仍能快速恢复；
- Animated WebP 在合理字节前缀到达后尽早播放；
- 弱网、低电量、高温或低内存时，应用自动降级但保持稳定；
- 应用逐渐学习用户的方向、速度和停留习惯，但不上传原始阅读轨迹作为默认行为。

## 3. 平台范围

### 3.1 首发范围

- Android 作为首个性能闭环平台。
- iOS 在核心接口稳定后实现同构能力。
- Flutter 负责产品 UI、阅读交互和资源策略。
- Rust 原生媒体内核负责增量容器解析、Animated WebP 解码、帧内存和可替换 GIF 解码。
- Kotlin/Swift 负责 Flutter texture、生命周期和平台设备状态桥接。

### 3.2 后续范围

- Windows、macOS、Linux。
- 云端书架同步。
- 远程全局模型训练与端侧个性化模型下发。
- 可插拔漫画源和内容扩展。

## 4. 核心目标

### G1：高性能阅读

- UI isolate 不执行网络阻塞、容器解析或重型解码。
- 当前页任务在 network/decode/upload 三个 lane 中均具有最高优先级。
- 目标页在翻页中点前成为 transition 资源角色。
- 已准备目标页不得出现空白切换。

### G2：可靠流式动画

- Animated WebP 使用可增长字节源和 native cursor。
- 下载前缀连续持久化，可在进程重启后恢复。
- 旧 epoch 的 cursor、decode 和 upload 结果不得覆盖新 source。
- 帧地址必须具有明确所有权和释放时机。

### G3：统一资源策略

- Reader 只报告阅读位置、交互和 viewport 信息。
- Policy 决定 download/decode/upload demand。
- Session 管理任务、lease、claim 和生命周期。
- Cache 只选择驱逐候选，Session 决定是否安全驱逐。

### G4：安全的端侧学习

- 第一版使用启发式策略。
- 第二版使用受约束上下文赌博机选择有限 DemandProfile。
- 模型不直接操作 transport、artifact、cursor、frame 或 texture。
- 探索不会作用于当前页最低保障。
- 高温、低内存、计费网络和模型异常时自动回退。

## 5. 非目标

首个生产版本不包含：

- 漫画编辑器；
- 社交网络；
- DRM 破解或绕过；
- 每帧深度强化学习；
- 模型直接控制文件和解码器生命周期；
- 通用视频播放器；
- 将所有静态图片强制纳入动画 native 路径；
- 在 UI Widget 中实现预下载或缓存所有权。

## 6. 架构原则

1. **Current first**：当前页优先级不可被学习策略降低到安全水位以下。
2. **Downward dependency**：上层只依赖下层抽象，下层不读取 UI 页面状态。
3. **Single authority**：每个 download identity 只有一个 authoritative artifact 和一个 active writer。
4. **Identity before cache**：缓存复用不能共享播放时序、cursor 或 decode identity。
5. **Epoch isolation**：source reset、重下、重绑定和真实 resize 必须改变 epoch。
6. **Demand over commands**：Policy 产生 demand，不直接发出资源命令。
7. **Detach is not eviction**：撤销需求不等于取消连接、删除文件或释放资源。
8. **Observable by default**：所有关键状态转移都有可测试事件。
9. **Safe fallback**：任何模型、native 或缓存故障都能回退到确定性路径。
10. **Measure before optimize**：每个优化必须对应可复现基准和指标。

## 7. 成功标准

### 7.1 功能标准

- 本地和远程章节可阅读。
- 支持 LTR、RTL 和纵向连续阅读。
- 支持静态图片与 Animated WebP。
- 下载中断后可恢复连续前缀。
- 旋转、后台、前台和 reader detach 不破坏 session 所有权。
- 清除缓存不会删除 active artifact。

### 7.2 性能标准

以下为项目目标，不是所有设备上的绝对保证：

- 静态页内存缓存命中时，输入到可见图像 P95 不高于 100 ms。
- 已 prepared 的 transition 页，dominant 到首帧 present P95 不高于 50 ms。
- 网络和解码任务不在 Flutter build/layout/raster 中同步执行。
- 连续 60 Hz 阅读场景中，应用自身造成的 >32 ms 帧少于 1/1000。
- current frame depth 低于安全水位时，near decode 自动降级。
- 资源使用始终受设备分级预算和系统内存警告约束。

### 7.3 质量标准

- 核心 session、identity、epoch、lease、eviction 状态机具备单元测试。
- Android texture 生命周期具备集成测试。
- 每次发布包含性能基线对比。
- 模型更新可禁用、可回滚、可重放。

## 8. 初始版本边界

### v0.1

- 本地章节与静态图片阅读。
- 远程下载、partial artifact、resume。
- current/transition/near 资源角色。
- 启发式策略。
- 基础 telemetry。

### v0.2

- Animated WebP native streaming。
- Android texture path。
- decoded frame holder 与 upload claim。
- 背景/前台生命周期。

### v0.3

- 完整缓存驱逐和设备预算。
- RTL、LTR、vertical 三种模式。
- shadow adaptive policy。

### v1.0

- 受约束端侧 bandit。
- iOS parity。
- GIF external fallback；是否实现 native GIF cursor 由基准决定。
- 发布级故障恢复、隐私和性能报告。
