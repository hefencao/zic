# dev.155 验证结果

## 已执行

- dev.75–dev.155 历史静态门禁通过；dev.98 因唯一基线缺少锁定 `third_party/source_archives/libwebp-1.6.0.zip` 未执行。
- 文档职责、Dart结构、library directive order、Pipeline compile boundary、test quarantine 与 Trace analyzer通过。
- dev.152 Cookie snapshot → 首个 Mihon OkHttp请求 handoff行为门禁通过；dev.154可见浏览器 Activity Kotlin编译通过；dev.155 Cloudflare真实 UA、详情路由、历史封面与插件持久恢复 owner门禁通过。
- Android runtime、texture bridge、Mihon entry/Context/ABI/classloader/read-only/chapter、Cloudflare classifier、Venera、source-resource、Reader/Pipeline/UI、external settings 与 native header合同通过。
- 候选 Patch 已在全新 dev.154 Git基线执行 `git apply --check --index` 与 `git apply --index`；应用后的 1059 个发行文件内容/执行位与工作树一致，`.zic-workspace.json` 哈希不变。
- 候选正式 ZIP 已独立解压；禁入文件检查、版本、核心结构、Cloudflare/Mihon/Venera/Reader/Pipeline/UI 与 native header复验通过。

## 环境限制

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK、Cargo/rustc和 ADB；因此不能声明 Flutter owner tests、APK、真机 Cloudflare、详情二次进入、历史封面和插件恢复已经通过。基线仍缺锁定 libwebp归档，未从旧版本补入。
