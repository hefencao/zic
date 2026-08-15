# dev.288 Pipeline dimension projection compile audit

## 触发事实

用户本地编译dev.287失败：`pipeline_reader_session.dart:623`无法解析`ValueListenable`。远程环境没有Dart/Flutter，因此dev.287的Python ownership/history gate只能证明源文本合同，不能替代Dart compiler；这与dev.281曾漏掉mutable field + const constructor属于同类验证边界。

## 审计结论

单纯增加`package:flutter/foundation.dart`虽然能修类型解析，却会继续保留不必要的框架耦合：Pipeline runtime用UI notifier作为公共dimension ABI，ReaderRuntime每个通知重新读取Map并遍历整章页面。该设计也把“retained事实重放”和“Flutter状态通知”两个责任混在一起。

## 收口

- 新增`PipelinePageDimensionsFeed`作为read-only event/replay boundary；私有publisher持有retained snapshot并按asset dedupe。
- event直接携带pageIndex/assetKey/width/height；Reader只处理该事实，不扫描整章。
- PipelineReaderSession删除Flutter imports，并将rootBundle包装移入asset adapter；chapter page identity在构造时一次索引。
- dev.287 gate更新为检查decode-ahead语义而非已被dev.288 supersede的`ValueNotifier`实现；新增dev.288 gate禁止Flutter notifier重新泄露。

## 验证边界

当前远程仍无Dart/Flutter，不能声称Dart编译已通过。dev.288交付前必须运行全部可用history/ownership/core与实际Kotlin compile；用户本地Dart/Flutter编译是该编译缺陷真正闭合的下一条设备/工具链事实。
