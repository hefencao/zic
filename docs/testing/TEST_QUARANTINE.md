# Test quarantine

默认测试套件不得用匿名 `skip`、布尔 `skip` 或仅写“flaky”的跳过项。临时隔离必须使用
`ZIC-QUARANTINE(dev.100):`，写明失效原因、仍在运行的所有者级覆盖以及解除条件。
`tool/check_test_quarantine.py` 对这些条件做静态门禁。

## dev.100 临时隔离

| 测试 | 原因 | 仍在运行的所有者级覆盖 | 解除条件 |
|---|---|---|---|
| `legacy runtime chapter URI refreshes before entering Reader` | Whole-App source-browser fixture 依赖旧的 catalog/route 启动顺序，超时不能证明 locator refresh 失败。 | `apps/app/test/source_resource_gateway_test.dart` 的 legacy Venera token 拒绝；`packages/plugin_host/test/runtime_source_adapter_test.dart` 的 runtime locator 规范化。 | 增加直接驱动 route facade 的可控 Future harness，不依赖主页、源列表和卡片 lazy 构建。 |
| `persisted legacy Venera chapter refreshes despite local-detail open hint` | 测试把书架卡片 bootstrap 时序与 locator refresh 所有者混为一体。 | 同上的 gateway/plugin-host 所有者级测试，以及持久章节读取测试。 | 使用预建 `ImportedLibraryEntry` 直接进入详情页，并显式控制 refresh Future。 |
| `source comic details retries a transient source failure` | Whole-App 测试在 source enablement、catalog bootstrap 和详情页 retry 之间竞争。 | 详情页错误状态与 source 调用分别由其 package/unit tests 覆盖。 | 新增直接构造 `RemoteComicDetailsScreen` 的 retry-state 测试，使用可控失败/成功 Future。 |

## 本轮删除的过时测试/断言

- 删除 App 层重复的 adaptive reader classifier 测试；该算法由
  `packages/reader_runtime/test/adaptive_reader_classifier_test.dart` 所有。
- 删除 `RasterPlan.isRenderUpscaled` 的测试和生产 getter。目标 canvas 会对极小输入做最小尺寸约束，
  该 getter 无法代表最终 widget renderer 是否放大。
- 删除把 Flutter `filterQuality` 等同于“codec 是否放大”的断言。codec 尺寸由 provider/resize
  合同验证，filter 只属于 renderer 采样策略。

隔离不是通过标准。新增隔离项必须更新本文件和门禁中的允许集合；修复后必须同时删除 `skip`
和本表对应项。
