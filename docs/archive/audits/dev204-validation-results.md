# dev.204 验证结果

## 变更范围

- `NetLane._retentionPriority()`：1/3 bounded + 2/3 headroom固定插值；admission/current-safe边界不变。
- `VeneraRuntimeDriver.httpWithUrlConnection()`：完整response关闭stream后保留平台连接复用机会；异常/取消仍disconnect。
- 版本、ADR/audit、静态gate及相关Dart测试契约更新。

## 已执行验证

通过：

- `git diff --check`；
- documentation responsibility；
- Dart structure：343 files / 129 test files；
- Dart library directive order；
- Pipeline runtime compile boundary；
- dev.175–204连续ownership/release gates；
- source-resource、Reader streaming、Pipeline demand、UI architecture、Android trace/frame analyzer；
- Venera network policy、source-requested cache helper、native binary、response headers、Reader preflight、bootstrap；
- Mihon entry/payload/ABI/classloader/read-only/chapter；
- Cloudflare typed classifier Kotlin compile/behavior；
- texture schedule与Android texture bridge Kotlin compile；
- native header；
- `python3 -m compileall -q tool`。

第一次平台组合批跑发生container ClientError，未产生测试输出，因此未计为通过/失败；随后按小组重跑上述项并取得实际PASS。

当前环境没有Dart/Flutter SDK；Dart行为测试已写入但不得声称执行。环境有Kotlin/Java。完整`bash tool/check.sh`已实际运行，仅在权威dev.203基线继承缺失的`third_party/source_archives/libwebp-1.6.0.zip`前置检查退出；未从旧版本补入archive。

## Replay / package

candidate与写入candidate结果后的pre-final replay均从原始dev.203完整ZIP fresh extract初始化baseline Git后实际执行；两轮均满足：

- `git apply --check --index`：PASS；
- `git apply --index`：PASS；
- work/replay：1256 / 1256；
- missing=0、extra=0、SHA-256/executable-bit different=0；
- ADR0185/0186、两份dev.204 audit与dev.204 gate均实际进入patch。

pre-final ZIP由同一冻结工作树生成，fresh extract后work/package同为1256个有效文件，missing=0、extra=0、SHA/executable-bit different=0；`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo`均为0。

在本审计事实冻结前还执行了一轮final replay/package，结果同样为work/replay/package=1256/1256/1256，missing=0、extra=0、SHA/executable-bit different=0、ZIP禁入项=0。由于本段本身会改变patch，release交付又从原始dev.203 ZIP重新执行一次最终fresh replay并重打同一冻结树ZIP；只有该后置复验再次取得相同数字才允许交付。
