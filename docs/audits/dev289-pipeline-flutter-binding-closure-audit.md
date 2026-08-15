# dev.289 Pipeline Flutter binding closure audit

## 触发事实

用户本地编译dev.288继续失败：`pipeline_page_output.dart:395/400`中的`WidgetsBinding`无法解析。dev.288只保证`pipeline_reader_session.dart`和dimension feed不再依赖Flutter notifier，但`part`文件仍能隐式依赖父library过去提供的Flutter import，因此静态文本gate没有覆盖完整Dart compilation unit。

## 仓库审计

`pipeline_runtime/lib/src`剩余Flutter耦合分为两类：

1. 合法显式adapter：`pipeline_media_runtime.dart`的opaque Widget surface ABI、`pipeline_reader_host.dart`的Widget composition、`asset_bundle_transport.dart`的rootBundle adapter。
2. 不合法隐藏owner：`pipeline_page_output.dart`直接`WidgetsBinding`，`pipeline_transfer_progress.dart`直接`SchedulerBinding + ValueNotifier`。

第二类属于resource/projection core，不应依赖Flutter frame/notifier实现；并且会随着顶层import整理反复产生compiler错误。

## 收口

- 用`PipelineFrameScheduler`抽象visual frame boundary，生产Flutter实现只放在`pipeline_native` presentation adapter。
- output stream通过scheduler延迟release旧`PresentClaim`，不再直接调用Flutter binding。
- transfer progress改为`PipelineTransferProgressFeed`，原逐帧coalescing通过同一scheduler维持；Reader用自身Stateful adapter消费feed；删除无消费者且重新暴露mutable publisher的`reader_download_progress.dart` typedef facade。
- compile-boundary gate遍历`pipeline_runtime/lib/src/*.dart`，Flutter import只允许三个显式adapter seam；同时明确禁止output/progress重新出现`WidgetsBinding/SchedulerBinding/ValueNotifier/ValueListenable`。

## 验证边界

当前远程环境仍没有Dart/Flutter SDK，不能宣称真实Dart compilation已经通过。dev.289必须运行全部可用history/ownership/core和实际Kotlin compile；用户本地Flutter/Dart compiler仍是这类错误真正闭合的下一条事实来源。
