# dev.150 Mihon runtime Release 保留审计

## 现象

系统已能发现扩展并尝试安装，但 activation 失败：

```text
Mihon common runtime is incomplete:
dev.zic.network.SourceVerificationRequiredException
```

这证明失败已越过 PackageManager、候选、metadata、签名、ABI metadata 和安装 staging，发生在扩展 entry 实例化前的 common runtime 完整性预检。

## 根因

`requiredMihonCommonRuntimeClasses` 要求 typed verification exception 保持原始类名；动态 ABI asset 也以该名称引用它。consumer R8 规则遗漏此类，因此 minified Release 可以重命名或裁剪它。其他 network common 类型已有 keep 规则，所以预检只报告该异常缺失。

## 修复

- 添加 `-keep class dev.zic.network.SourceVerificationRequiredException { *; }`。
- 保留 common runtime 预检，不降级为字符串消息判断。
- 新增从 required class list 反查 network consumer keep rules 的门禁。
- Mihon host ABI test 明确要求 typed exception 留在稳定边界。
