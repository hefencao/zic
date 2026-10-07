# dev.133 验证结果

## 已通过

- repository/documentation/Dart structure/directive order/compile boundary。
- dev.75–dev.133 历史静态门禁。
- Android runtime、Trace export、Mihon、Venera、Reader、Pipeline、UI 与外部登录/设置合同。
- `TextureBridgePlugin.kt` 使用最小 Android/Flutter stub 的 Kotlin 编译。
- native C header smoke。
- 锁定 `libwebp 1.6.0` 全新 shared host build；incremental、blend 与 finite-loop smoke。
- dev.133 专项门禁：10 项/256 MiB、memory-direct、单 blit lane/main channel、实际 TID/cpuset affinity 与 native identity。

## 未验证

- 当前环境没有 Flutter/Dart SDK，未执行 `flutter analyze`、Dart owner tests 或 APK 构建。
- 当前环境没有 Cargo/Android NDK，未编译 Android Rust affinity 路径。
- 未在用户设备验证后台重入首帧、单块 native ingress、platform schedule 长尾和 `workerPlacementStatus=1`。

## 修复前设备基线

- mount-to-first-frame：p50 `78,191 us`，p95 `930,133 us`，max `2,260,511 us`。
- current memory hit：`deliveryMode=startup-segmented`、18 chunks、`streamMicros=970,861`。
- origin current：18,319,682 bytes、`streamMicros=3,359,779`。
- present：p95 `109,233 us`，max `1,537,225 us`。
- worker placement：80/80 status 3。
