# ADR 0135：Mihon common runtime 的 Release 保留边界

**状态：Accepted**

## 背景

Mihon 扩展已经被设备发现并进入隔离 runtime activation，但 Release APK 在 common runtime 完整性预检时缺少 `dev.zic.network.SourceVerificationRequiredException`。该异常既由动态 Mihon ABI asset 抛出，也由 App host 识别；双方必须通过原始全限定类名共享同一类型。`network_bridge` 的 consumer R8 规则保留了 interceptor、CookieJar、snapshot store 和 DNS，却遗漏了验证异常。Release shrink/obfuscation 因而可以重命名或裁剪该类，debug/static Kotlin 检查仍无法暴露问题。

## 决策

1. `SourceVerificationRequiredException` 作为动态 common runtime ABI 类型，必须以原始名称和成员保留在 Release APK。
2. 不删除 `requiredMihonCommonRuntimeClasses` 中的异常预检来绕过问题；缺类应在扩展实例化前 fail closed。
3. 所有列入 `requiredMihonCommonRuntimeClasses` 的 `dev.zic.network.*` 类型必须在 `network_bridge/android/consumer-rules.pro` 中具有显式 `-keep class ... { *; }`。
4. 静态门禁从 common runtime 列表反向检查 keep 规则，新增网络边界类型时必须同时更新 Release 保留合同。

## 后果

Release 构建不会再把 typed verification exception 重命名为仅 App 可见的内部名称，Mihon ABI asset 与 host driver 可以共享同一异常类型。扩展发现、信任、ABI 和 entry 校验保持不变。
