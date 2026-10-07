# dev.130 Retained Output Projector 编译闭包审计

## 唯一基线

`zic_v0.31.0-dev.129_fresh-reader-texture-performance-core-deadline-wake.zip`

## 问题分类

### 编译问题

`packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart` 的 Android projector 仍执行：

```dart
if (frame is _RetainedAndroidTextureOutputFrame)
```

但 dev.129 已删除该私有类型定义，Dart 编译因此失败。

### 产品问题

无新增产品逻辑问题。本轮不改变 fresh texture、下载、解码、播放或 Reader 生命周期。

### 性能问题

无新增性能策略。本轮只闭合 dev.129 删除 retained output 后的投影器引用。

### 测试问题

dev.129 静态门禁只禁止 retained 类型的定义及恢复 capability，没有禁止生产代码中的残余类型判断，因而漏检。

## 所有权

- Android `OutputFrame -> PipelinePageSurface` 投影：`pipeline_native`。
- retained output 已由 ADR 0113 删除，不得由 `sessions`、Reader 或 projector 恢复。
- 编译闭包门禁：`tool/test_dev130_retained_output_projector_compile_closure.py`。

## 拒绝方案

- 不重新定义 `_RetainedAndroidTextureOutputFrame` 空壳来绕过编译。
- 不把判断改成字符串、dynamic 或 reflection。
- 不恢复跨 Reader retained output。
- 不修改测试来忽略编译错误。

## 修复

删除 projector 中已不可达的 retained-frame 分支。Android projector 只接受当前权威 `_AndroidTextureOutputFrame`，否则继续抛出 `ArgumentError`。
