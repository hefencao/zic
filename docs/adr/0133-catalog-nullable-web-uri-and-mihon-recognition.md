# ADR 0133：Catalog 可空 Web URI 与 Mihon 识别边界

**状态：Accepted**

## 背景

`ComicWebUriSource.resolveComicWebUri` 的公开合同返回 `Uri?`，但缓存装饰器错误收窄为非空 `Uri`，Dart 编译因此拒绝直接返回来源的可空结果。与此同时，dev.147 为 Cookie snapshot reset 让 Mihon driver直接依赖 `AndroidBrowserCookieSession` 并将其加入 common runtime必需类；该类是 network bridge内部状态实现，不应成为扩展激活前的 ABI门槛。部分 APK还会把 extension metadata写成 `@string` 资源，旧 reader把资源 ID整数当字符串解析并提前过滤候选。

## 决策

1. `CachedBrowsableComicSource.resolveComicWebUri` 保持 `Uri?`，不强制非空；调用方沿用 descriptor website fallback。
2. browser snapshot revision reset由 `AndroidCookieJar.resetBrowserSnapshotImports()` 暴露。Mihon driver只依赖该稳定 adapter，不 import或预检 `AndroidBrowserCookieSession`。
3. Mihon installed-package候选按 `tachiyomi.extension` feature或标准 package prefix识别，不在候选阶段要求 entry metadata已是直接字符串。
4. extensionLib和entry class metadata支持 manifest直接字符串与 Android字符串资源。entry class列表支持逗号、分号和换行，展开相对 package class名后再做严格类名校验和去重。
5. package、signer、version、ABI和 entry class的完整信任校验仍在加载前执行；识别放宽不等于绕过信任。
6. 后台设备扩展扫描错误由 `ExternalPluginController` 保留并在 Mihon 插件页呈现；只有扫描成功才清除，不再静默降级为空列表。

## 后果

Catalog 编译合同恢复一致。Mihon插件不会因为 network bridge内部实现类缺失/裁剪而在 entry加载前整体拒绝；资源型 metadata和常见多入口格式可以被识别，同时不降低签名和 ABI校验。
