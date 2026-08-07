# dev.153 验证结果

## 已执行

- 文档职责、Dart structure、directive order、Pipeline compile boundary。
- dev.75–dev.153 历史所有权门禁；dev.98 因 dev.152 基线缺少锁定 `third_party/source_archives/libwebp-1.6.0.zip` 未执行。
- shared network browser bridge Kotlin 实际编译。
- Cloudflare typed classifier / Mihon compatibility wrapper Kotlin 实际编译与行为正反例；`challenge-platform`/`cf-chl-*`脚本、`Just a moment`和普通 Cloudflare 403不再误判为交互 challenge。
- Mihon browser snapshot → 首个 OkHttp request同步 Cookie行为测试。
- Android runtime、Trace、texture schedule与 texture bridge Kotlin合同。
- Mihon entry、Context、ABI、split classloader、read-only APK staging、chapter catalog合同。
- Venera network/native/headers/preflight/bootstrap。
- source-resource、Reader layout、Pipeline demand、Reader streaming、UI architecture、external source settings/login与 native header合同。

## 设备错误闭包

- `ComicDetailsSourceWebViewOpener` 两处调用已改为带 `{Uri? verificationUri}` 的 named callback，闭合错误报告中的函数类型不匹配。
- 浏览器 `network-browser-cancelled` 不再先破坏已有 same-site/same-UA snapshot；打开验证浏览器时保留仍在 TTL 内的旧 Cookie/localStorage，成功 capture才推进 revision。
- 手动或自动 browser handoff后，若 replacement runtime仍失败，后续普通刷新不再再次自动打开同一 WebView；手动验证入口仍保留。

## 交付闭环

- Patch已在全新 dev.152临时 Git基线执行 `git apply --check --index` 与实际 `git apply --index`；应用树的 1050 个发行文件内容和执行位与工作树一致，`.zic-workspace.json` 哈希未改变。
- 正式 ZIP候选已独立解压复验：版本/禁入路径、文档/结构、dev.147/dev.152/dev.153、同步 Cookie handoff、network browser bridge、Cloudflare classifier、Android runtime/Trace/texture、Mihon Context/ABI/classloader/read-only/chapter、Venera、source-resource、Reader/Pipeline/UI、external source settings与 native header均通过。
- 写入本条最终验证记录后只变更审计文档；最终 Patch/ZIP重新生成并再次执行文档与 dev.153门禁，不再修改产品代码。

## 环境限制

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK与 ADB，因此 Flutter Widget owner tests、Release APK和真实 18comic网络流程未在本机执行。基线缺少锁定 libwebp归档，因此不从旧版本补入或伪造 dev.98/WebP source build通过。
