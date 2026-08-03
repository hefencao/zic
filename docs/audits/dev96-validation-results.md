# dev.96 本地 WebP 播放验证结果

## 环境

- 可用：Python 3、Bash、Git、CMake、Ninja、`patch`、Node.js、Java、Kotlin compiler。
- 不可用：Flutter SDK、Dart SDK、Cargo/rustc、Gradle、Android SDK/`sdkmanager`、ADB。
- 外网源码获取受限：`chromium.googlesource.com` 在执行容器中 DNS 解析失败。

## 已通过

1. `bash -n tool/*.sh`。
2. `python3 -m py_compile tool/*.py`。
3. repository、Dart structure（323 个 Dart 文件、121 个测试文件）、library directive order、Pipeline runtime compile boundary。
4. dev.75–dev.96 全部静态所有权/回归门禁。
5. 纵向几何、Android runtime dependency、Android Trace export。
6. Mihon entry、Context、ABI routing、classloader、read-only staging、chapter contract。
7. Venera network policy、native binary、response headers、Reader preflight、bootstrap。
8. source resource binding、Reader layout settings、Pipeline demand stability、Reader streaming、UI architecture、external login/settings。
9. native public header contract。
10. dev.96 libwebp patch 门禁：对与 v1.6.0 `VP8New`/`VP8Clear` 真实上下文一致的 fixture 执行 `patch --dry-run` 成功；构建脚本、patch identity、禁用额外 `WebPSetWorkerInterface` 和单线程 decode 合同通过。
11. 公共 API 全仓引用闭包：无遗留 worker `acquire/release`、`decode.replace`、`upload.replace`、二次 alpha 预乘、每帧 `ANativeWindow_setBuffersGeometry` 或额外 native worker interface 引用。

## 未执行或受环境阻塞

- `flutter analyze`、Dart/Flutter package tests、App tests：Flutter/Dart SDK 不存在。
- Android debug/release 或 kernel snapshot：Flutter、Gradle、Android SDK 不存在。
- Rust 单元测试与 native crate 编译：Cargo/rustc 不存在。
- `tool/check_webp.sh` 的完整 libwebp v1.6.0 获取、补丁应用、C smoke：执行到 exact pinned source fetch 时因 `Could not resolve host: chromium.googlesource.com` 退出 128；不是源码或 patch 门禁失败。
- 真机帧率、纹理生命周期与 transition→current Trace：本轮未附带新设备 Trace，需在 Android 设备上验证。

## 干净包复验

- candidate ZIP 已重新解压；禁用生成物扫描为空，repository、Dart structure、directive order、Pipeline compile boundary、dev.93–dev.96、Android dependency、Mihon ABI、Venera、Reader streaming、UI architecture、bootstrap 与 native header 复验通过。长合同组按执行窗口拆分运行，超时发生在测试之间，未出现失败输出。
