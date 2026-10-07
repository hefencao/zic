# ADR 0134：Mihon 共享扩展端到端发现与诊断

**状态：Accepted**

## 背景

dev.148 放宽了 APK候选和 metadata解析，但设备仍可能显示“未检测到扩展”。根因是设备发现只调用一次 `getInstalledPackages()`，每个候选又通过 `runCatching(...).getOrNull()` 静默丢弃。应用可见性受限时没有候选；manifest、签名、ABI或 entry失败时也没有错误。精确 package探测只有用户手动加载仓库后才有输入。

当前 Mihon同时存在系统共享扩展 APK与 Mihon App私有目录扩展。后者位于另一个 App的私有存储，ZIC不能跨进程枚举或复制。

## 决策

1. App manifest声明 `QUERY_ALL_PACKAGES`，设备发现合并 `getInstalledPackages()`、`getInstalledApplications()` 和 `getPackageInfo(packageName)`。
2. Mihon页面打开时自动加载默认仓库索引，以仓库 plugin ID中的 package name执行精确探测。仓库加载失败与设备扫描失败分开呈现。
3. 单个 APK的 candidate、direct query、metadata、signer、ABI和 entry失败必须进入结构化 scan结果，不能转为空列表。
4. UI显示系统枚举、候选、精确探测、精确命中和逐 APK失败阶段。
5. 设备扫描只声称支持系统共享扩展 APK。Mihon私有目录扩展必须从 ZIC仓库独立安装；不得尝试读取另一个 App的私有目录。
6. 扫描只负责发现与 metadata检查。信任审批、payload hash、signer、version、ABI、entry和隔离进程激活仍由现有安装链执行。

## 后果

用户可以区分“设备没有共享扩展”“系统隐藏包列表”“APK metadata不兼容”和“扩展激活失败”。仓库 package精确探测为 OEM可见性限制提供第二条路径，但不会绕过 Android私有存储边界。
