# dev.175 验证结果

## 已执行

- `check_dart_structure.py`、全部 `tool/*.py` 语法编译与 `tool/check.sh` shell 语法检查通过。
- dev.75–dev.97、dev.99–dev.175 历史 ownership/contract gates 全部通过；dev.78、dev.161、Venera native-binary 与 Reader-preflight 静态门禁仅迁移被 dev.175 controlled API 明确取代的旧字面实现契约，产品代码未为过门禁回退。
- source-resource atomic binding、Reader streaming、Pipeline demand stability、UI architecture、Venera bootstrap/network/native-binary/response-header/Reader-preflight 合同通过。
- Mihon payload Context、ABI routing、classloader、entry、read-only、chapter contract通过；Android runtime dependency closure与 texture bridge Kotlin stub compile通过。
- native C header静态检查通过。

## 基线继承阻断

- `check_repo.py` 与 dev.98 libwebp archive gate仅因当前 dev.174基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` 而停止；未从旧版本补入该归档。

## 当前环境无法执行

- 当前环境没有 Dart/Flutter SDK，因此新增 controlled Venera priority/cancel 与 controlled source-loader Dart行为测试已纳入源码但未实际运行；未声明 analyzer、Flutter tests或 APK build通过。
- 当前环境没有 Rust/Cargo，因此 `media_core` 的既有/新增 Rust单测无法执行；本轮以 native锁所有权静态门禁与保持既有 `decode_next()` wrapper/FFI ABI约束验证。
- 没有完整 Android SDK/NDK/ADB，因此真机 current source-plan抢占、`nativeIngressMicros` 与 UI frame timing仍需设备复验；本轮不新增 `Verified-device` 结论。
