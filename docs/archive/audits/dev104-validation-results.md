# dev.104 Validation Results

- 源码：`0.31.0-dev.104`
- App build：`0.31.0+104`
- 设备修复效果：未验证

## 当前环境已执行

- repository、documentation、Dart structure、directive order；
- Pipeline runtime compile boundary；
- dev.75–dev.104 ownership gates；
- quarantine、texture timing、Trace analyzer；
- Android texture Kotlin stub compile；
- Android/Mihon/Venera/Reader/Pipeline/UI 静态合同；
- native header；
- 锁定 `libwebp-1.6.0.zip` 的零 fuzz prepare；
- host shared CMake/Ninja build；
- incremental 与 loop Animated WebP smoke。

长组合检查因单次执行窗口分段，后续从未执行项继续；没有把超时记为通过。

## 新增源码级回归

- foreground 压力期 background quantum 限流；
- 无 foreground 压力时 background 恢复全部容量；
- pending foreground 优先；
- pending role refresh；
- background stream 每 chunk 重新申请；
- foreground stream 连续持有 lease；
- background→current 在下一 chunk 原地晋升且只打开一次 artifact；
- retained frame detach 后 cursor 从下一 frame 继续，不重建 frame 0。

这些 Dart tests 已写入 owning package，但当前环境无 Dart/Flutter SDK，因此未实际执行。

## 未执行

- `flutter analyze`；
- Dart/Flutter tests；
- Android debug/release；
- Rust tests；
- Android 真机首次进入、早期切页和新页连续播放复验。
