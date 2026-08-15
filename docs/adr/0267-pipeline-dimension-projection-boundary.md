# ADR 0267：Pipeline dimension projection boundary

状态：Accepted
版本：dev.288

## 背景

dev.287为了解开vertical geometry对UI/output尺寸上报的依赖，将decode frame dimensions提前投影到`PipelineReaderSession.pageDimensions`。用户本地真实Dart编译随后报错：公共getter声明`ValueListenable<Map<String, PipelinePageDimensions>>`，但该源码未声明foundation中的`ValueListenable`。直接补Flutter import可以消除单点编译错误，却会把临时UI notifier继续固化为Pipeline/Reader公共ABI，并保留Reader每次通知pull整章Map重新扫描的重复工作。

## 决策

- Pipeline尺寸边界改为领域自己的只读`PipelinePageDimensionsFeed`。consumer只有add/remove listener能力；listener attach默认按pageIndex重放当前retained facts，保证Reader re-entry不丢decode-ahead尺寸。
- 每个`PipelinePageDimensions`事实携带`pageIndex`、稳定`assetKey`、`width/height`；ReaderRuntime直接校验identity后进入既有`_reportPageDimensions` owner，不再pull notifier Map或逐页扫描。
- `_PipelinePageDimensionsPublisher`保持library-private；publish、dedupe、clear/dispose只属于`PipelineReaderSession`。公共边界不得出现`ValueNotifier`/`ValueListenable`，尺寸metadata仍不得参与download/decode/upload admission。
- `PipelineReaderSession`预构建chapter `pageId -> pageIndex`索引，source-kind、decode dimensions、animation classification共享同一identity resolver，删除三条独立`indexWhere`扫描。
- `pipeline_reader_session.dart`不直接import Flutter UI/services；asset bundle全局细节由`AssetBundleTransport.root()` adapter封装。该改动不改变asset transport authority或资源策略。
- dev.287的decode-ahead时序与vertical future-tail安全采用规则保持不变；dev.286 presentation workaround仍为Superseded。

## 不变量

- ReaderRuntime继续是`pageAspectRatios`唯一projection owner，ReaderView继续是vertical geometry adoption owner。
- retained Pipeline session可以重放dimension facts，但不能形成第二个geometry cache/policy owner。
- previous3/next7、decode2/1、holder7/5/3/2、NetLane 5+1、dev.281 hidden-next2 upload deferral、dev.285 promoted hot retention均不变。
