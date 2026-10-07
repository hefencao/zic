# dev.148 Catalog URI 与 Mihon 识别审计

## 基线

`zic_v0.31.0-dev.147_reader-progress-version-view-start-action-verification.zip`

## 问题

1. `CachedBrowsableComicSource.resolveComicWebUri` 声明 `Uri`，委托接口返回 `Uri?`，形成确定编译错误。
2. dev.147 把 `AndroidBrowserCookieSession` 从 network内部实现提升为 Mihon driver直接 import和 common runtime硬前置。扩展尚未实例化即可被 common ABI预检拒绝。
3. APK metadata reader对 `Bundle` 中的资源 ID直接 `toString()`，`@string` entry/ABI值会变成数字并识别失败。
4. 后台首次设备扩展扫描异常被吞掉并替换为空列表，设备特有的识别错误会误显示为“未检测到”。
4. entry class仅支持分号，多个入口使用逗号或换行时会整体判为非法。
5. installed candidate过滤同时要求 entry metadata存在，使可解析的资源型 metadata在 inspect前被排除。

## 修改

- 恢复 Catalog `Uri?` 合同。
- reset入口迁至 `AndroidCookieJar` 稳定边界，并移除内部 session common ABI项。
- metadata reader先解析字符串资源，再执行 entry/ABI校验。
- entry parser支持逗号、分号和换行，保持严格类名校验及去重。
- installed candidate只使用 feature/package prefix；完整 metadata/trust检查仍在 inspect阶段。

## 拒绝方案

- 不用 `!` 强制来源 URI非空。
- 不删除 package/signature/version/ABI/entry信任检查。
- 不把 `AndroidBrowserCookieSession` 复制到 plugin host。
- 不把设备扫描异常静默转换成空列表；保留并显示真实错误。
- 不通过扫描任意 DEX字符串猜测入口类。
