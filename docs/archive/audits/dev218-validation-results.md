# dev.218 验证结果

目标版本：`0.31.0-dev.218` / App `0.31.0+218`

## 已验证（当前环境）

- repository/documentation/ownership静态门禁。
- dev.218 source-wake/slider结构门禁。
- 相关历史Reader/Pipeline调度门禁；dev.217 single physical task约束保持。
- Kotlin可用的既有compile stub门禁。
- Patch replay与完整ZIP逐文件/类型/可执行位一致性（发行阶段记录）。

## 已实现但未执行

- Dart行为回归：next2 source-ready wake在current bootstrap门控期间保持pending，随后晋升current必须从同一ready projection decode出帧。
- Flutter widget回归：真实Slider gesture移动到目标页时，受控value在acknowledge前保持requested index。

当前环境没有Dart/Flutter SDK，因此不得把上述两项记为runtime pass，也不得声称`flutter analyze`、Flutter tests或APK build通过。

## 已知基线限制

完整`tool/check.sh`仍会在唯一基线缺少`third_party/source_archives/libwebp-1.6.0.zip`的pinned-source检查处停止；不得从旧版本或独立包偷补。

## 设备复验重点

1. 已`sourceReady/artifactPromoted`的current页面不得继续长期`waitingSource`；黑页样本应重新出现`decodeRefill/decodeStarted/firstFrameReady`。
2. current network抢占继续保持；`sessionBusy/writerBusy`不得重新出现。
3. slider连续拖动时thumb不回弹，并可跨多页完成jump。
