# dev.250 验证结果

## 基线与问题

- 唯一代码基线：`zic_v0.31.0-dev.249_animated-webp-frame-flow-backpressure.zip`。
- 用户本地Flutter/Dart编译错误：`ByteResponse.flowControl` getter不存在、constructor initializer不是instance field；rhttp bridge无法解析`ByteResponseFlowControl`。

## 修复闭包

- `transport.ByteResponse`新增唯一typed instance field：`final ByteResponseFlowControl flowControl;`，与dev.249既有constructor parameter/default闭合。
- `downloads`既有transport facade export补导出`ByteResponseFlowControl`，`downloads_bridge`仍不新增对`transport`的第二直接依赖。
- direct transport继续声明`streamBackpressure`；artifact/source wrappers继续只透传`response.flowControl`；DownloadJob仍是frame-credit capability唯一消费方。
- dev.249的3/7 demand、frame credit、水位、NetLane、partial/progress/provider lifetime完全未修改。

## 当前环境验证

- dev.205..dev.250历史/ownership gates：46/46 PASS，最多8 workers。
- 核心门禁：10/10 PASS。
- Dart structure：361 Dart files / 135 test files。
- Pipeline runtime compile-boundary静态检查：PASS。
- Android texture Kotlin compile：PASS。
- `tool/check.sh`：仍在基线缺失`third_party/source_archives/libwebp-1.6.0.zip`的首项检查停止。

当前环境无Dart/Flutter/Cargo，因此不能声称真实Dart/Flutter编译已在本环境执行；本轮新增gate专门补足公共API结构闭包，用户下一次本地Flutter build仍是编译实证。
