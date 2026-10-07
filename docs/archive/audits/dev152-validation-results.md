# dev.152 验证结果

## 已执行

- Dart结构、directive order、Pipeline compile boundary。
- 历史 dev门禁与 dev.152 专项合同。
- Cloudflare typed classifier/wrapper Kotlin编译与正反例。
- Mihon browser snapshot → 首个 OkHttp request同步 Cookie行为测试：测试 CookieManager不保存写入时仍能得到 `cf_clearance`。
- shared network browser bridge Kotlin编译。
- Mihon Context、ABI、classloader、read-only、chapter合同。
- Patch 已在全新 dev.151 基线完成 `git apply --check --index` 与实际 `git apply --index`；应用后的 1046 个发行文件内容和执行位与工作树一致，`.zic-workspace.json` 哈希不变。
- 正式 ZIP 候选已独立解压复验：版本/禁入文件、文档/结构、dev.151/dev.152、同步 Cookie行为、network browser bridge、Cloudflare classifier、Mihon Context/ABI/classloader/read-only/chapter、Venera、source-resource、Reader/Pipeline/UI、texture bridge与 native header均通过。

## 环境限制

当前环境无 Flutter/Dart SDK、完整 Android SDK/NDK与 ADB，因此 Flutter owner tests、Release APK和真实 18comic Cloudflare流程仍需本地/真机验证。
