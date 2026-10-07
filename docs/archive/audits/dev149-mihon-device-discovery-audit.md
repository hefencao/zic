# dev.149 Mihon 设备扩展发现审计

## 唯一基线

`zic_v0.31.0-dev.148_catalog-uri-mihon-recognition.zip`

## 根因

- `getInstalledPackages()` 是唯一初始发现入口。
- 候选解析使用 `mapNotNull + runCatching + getOrNull`，所有单 APK失败静默消失。
- 精确 package探测依赖 `_entries`，但仓库不会在页面打开时自动加载。
- UI只知道空列表或整次 MethodChannel失败，无法区分应用可见性、metadata、签名、ABI和 entry错误。
- Mihon私有扩展不是系统安装包，不能由其他 App的 PackageManager发现。

## 修改

- 新增结构化 scan协议、三路发现、仓库自动加载、精确探测和逐 APK诊断。
- manifest加入 `QUERY_ALL_PACKAGES`。
- 修复 dev.148 Dart扫描协议中的实例方法 tear-off、package name pattern和换行闭包。
- UI明确系统共享与 Mihon私有扩展边界。

## 未改变

- package/signer/version/ABI/entry信任合同。
- 安装前审批与私有 payload复制。
- Mihon隔离进程和 source identity。
