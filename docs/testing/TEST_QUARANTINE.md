# Test Quarantine

默认测试套件不得使用匿名 `skip`、布尔 `skip` 或仅写“flaky”的跳过项。临时隔离必须使用稳定 ID，并登记原因、仍运行的所有者级覆盖和解除条件。

| ID | 测试 | 原因 | 仍在运行的所有者级覆盖 | 解除条件 |
|---|---|---|---|---|
| `Q-001` | `legacy runtime chapter URI refreshes before entering Reader` | Whole-App fixture 依赖 catalog、route 和 lazy 页面启动顺序，超时不能证明 locator refresh 失败。 | `source_resource_gateway_test.dart` 的 legacy Venera token 拒绝；`runtime_source_adapter_test.dart` 的 runtime locator 规范化。 | 直接驱动 route facade，使用可控 refresh Future，不依赖主页和源列表。 |
| `Q-002` | `persisted legacy Venera chapter refreshes despite local-detail open hint` | 测试把书架 bootstrap 与 locator refresh 所有者混为一体。 | gateway/plugin-host 所有者测试和持久章节读取测试。 | 预建 `ImportedLibraryEntry`，直接进入详情并控制 refresh Future。 |
| `Q-003` | `source comic details retries a transient source failure` | Whole-App 测试在 source enablement、catalog bootstrap 和详情 retry 之间竞争。 | 详情错误状态和 source 调用的 owner tests。 | 直接构造 `RemoteComicDetailsScreen`，注入可控失败/成功 Future。 |

测试中的标记格式：

```text
ZIC-QUARANTINE(Q-001):
```

隔离不是通过标准。修复后必须同时删除 `skip`、表项和门禁 allow-list。新增隔离项必须说明为什么 owner-level harness 暂时不可行；不得用 quarantine 掩盖编译错误或产品回归。
