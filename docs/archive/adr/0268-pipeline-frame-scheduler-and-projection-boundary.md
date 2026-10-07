# ADR 0268：Pipeline frame scheduler and projection boundary

状态：Accepted
版本：dev.289

## 背景

dev.288把decode尺寸公共边界从Flutter `ValueListenable`收口成Pipeline自有feed，但用户本地真实Dart编译继续暴露`pipeline_page_output.dart`中的`WidgetsBinding`未解析。审计发现这不是孤立import遗漏：`PipelinePageOutputStream`直接使用`WidgetsBinding`延迟visual claim release，`PipelineTransferProgressPublisher`同时直接依赖`SchedulerBinding + ValueNotifier`做逐帧合并。因为`pipeline_page_output.dart`是`pipeline_reader_session.dart`的part，顶层session移除Flutter import后，隐藏依赖才被真实compiler揭露。

## 决策

- 新增框架无关`PipelineFrameScheduler`，只暴露persistent-callback/idle phase查询、after-frame callback与frame request。Pipeline output与transfer projection只依赖该能力，不认识Flutter binding/type。
- `PipelineMediaRuntime`提供`frameScheduler`，因为visual swap、surface presentation与Flutter frame boundary属于同一presentation adapter。生产实现由`pipeline_native`的`_FlutterPipelineFrameScheduler`统一桥接`SchedulerBinding`。
- `PipelinePageOutputStream`仍由Pipeline拥有`PresentClaim`；旧claim只在listener已消费replacement后的下一visual frame boundary释放，但具体Flutter post-frame实现不再位于resource runtime。
- transfer progress改为Pipeline自有只读`PipelineTransferProgressFeed`。`PipelineTransferProgressPublisher`保留原来的frame-coalescing语义，但通过`PipelineFrameScheduler`调度；ReaderRuntime拥有一个Flutter Stateful adapter订阅feed，不再消费`ValueListenableBuilder`。旧`reader_download_progress.dart`只剩将publisher重新暴露给Reader的无消费者typedef facade，现一并删除。
- `pipeline_runtime/lib/src`允许Flutter import的显式seam收成三个文件：`pipeline_media_runtime.dart`（opaque Widget surface ABI）、`pipeline_reader_host.dart`（Widget composition host）、`asset_bundle_transport.dart`（rootBundle adapter）。其他resource/session/projection文件不得直接依赖Flutter binding/notifier/scheduler。

## 不变量

- frame scheduler只决定presentation/projection callback何时安全发布，不参与download/decode/upload admission、priority、holder或texture scheduling。
- Reader仍不能claim/present/advance/dispose Pipeline output；visual claim lifetime owner仍在Pipeline。
- dev.287/288 decode dimension feed、dev.285 promoted hot retention、dev.283 visible-target authority、dev.280/281 geometry与dev.282 resident reuse均不变。
