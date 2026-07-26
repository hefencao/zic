# ADR-0001: Flutter + Dart Orchestration + Rust Media Core

## Status

Accepted for initial implementation.

## Context

`zic` 需要同时满足：

- 快速构建跨平台产品 UI；
- 高性能 Animated WebP 流式解码；
- 清晰的资源策略和 session 生命周期；
- 后续端侧学习；
- Android/iOS texture 能力。

单纯 Dart 实现所有增量解码和帧内存会增加 UI/runtime 边界风险。全原生实现则显著增加产品迭代和跨平台成本。

## Decision

- Flutter：UI、Reader、Library、设置。
- Dart：policy、window、ranker、session coordinator、transport、artifact、telemetry、轻量模型。
- Rust：增量容器解析、Animated WebP cursor、帧组合和帧内存。
- Kotlin/Swift：Flutter texture、平台生命周期、设备状态。
- FFI：Dart 与 Rust 控制接口。
- 不通过 MethodChannel 传输完整 RGBA 帧。

## Consequences

### Positive

- 产品层迭代快。
- 媒体执行层可独立测试和基准。
- 格式 runtime 可替换。
- 端侧线性模型可直接在 Dart 中实现。
- Android/iOS 共享大部分业务和策略代码。

### Negative

- 需要维护 Dart、Rust、Kotlin、Swift 四种语言边界。
- frame ownership 和 texture 生命周期必须严格设计。
- FFI ABI 需要版本化。
- 调试工具链更复杂。

## Guardrails

- Rust 不读取 Reader UI 状态。
- Dart 不持有裸 frame 指针。
- Platform texture 不拥有下载 session。
- Policy 不直接调用 native decoder。
- ABI 变化必须更新 conformance tests。
