# dev.105 Validation Results

- 源码：`0.31.0-dev.105`
- App build：`0.31.0+105`
- 基线：dev.104 完整 ZIP 独立解压

## 已执行并通过

- `bash -n tool/*.sh`
- `python3 -m py_compile tool/*.py`
- repository、documentation、Dart structure、directive order
- Pipeline runtime compile boundary
- dev.75–dev.105 静态 ownership/regression gates
- quarantine、texture timing、Trace analyzer fixture
- Android texture Kotlin stub compile
- Android runtime/dependency/Trace contracts
- Mihon entry、payload Context、ABI、classloader、只读 staging、chapter contracts
- Venera network、native binary、response headers、Reader preflight、bootstrap contracts
- source binding、Reader settings、Pipeline demand/streaming、UI architecture、external login/settings contracts
- native header check
- 锁定 `libwebp-1.6.0.zip` 的零 fuzz prepare
- host shared CMake/Ninja build
- incremental 与 loop Animated WebP smoke

完整 `tool/check.sh` 一次在前段达到单次执行窗口，随后按未执行项分组续跑；续跑项没有失败。超时未计为通过。

## 新增但当前未执行的 Dart 测试

- `promoted_artifact_byte_cache_test.dart`：并发合并、LRU、长度漂移拒绝
- `artifact_cache_transport_test.dart`：foreground read-all、memory hit、失败回退 stream
- `artifact_test.dart`：大于 1 MiB promoted file 精确读取
- `media_runtime_ownership_test.dart`：factory clone 保持 composition cache identity

当前环境没有 Dart/Flutter SDK，因此这些测试仅完成源码与静态引用闭包，未宣称运行通过。

## 未执行

- `flutter analyze`
- Dart/Flutter package 与 App tests
- Android debug/release 和真机 Trace
- Rust tests（当前环境无 Cargo/rustc）

## 设备验证要求

下一份 dev.105 Trace 应至少出现 `artifactReadMode`、`artifactMaterializeMicros`、`memoryCacheHit`、`memoryCacheJoined`、`hotCacheEntries` 和 `hotCacheBytes`。需要分别比较首次 current、background、快速 Reader 重进；确认 read-all 失败时只回退 promoted stream。
