# dev.239 task-retained transport root-cause audit

## 问题清单

### 产品/性能问题
- 05:09真机Trace共1176条事件，`taskFailed=0`；dev.238后未再出现claim-orphaning provider handoff，`full-body-prefix-catchup-aborted=0`，说明上一轮边界有效。
- resume duplicate仅一次65,536-byte validatorless overlap proof；但多个loader-backed physical transfer在Reader consumer真实dispose时仍被取消，已提交partial包括4,064,640、4,763,980、4,752,300与7,994,960 bytes。
- 后续Reader确实复用这些physical partial而非新建空session；其中4,064,640-byte partial的resume probe收到HTTP 200并进入full-body prefix catch-up，另外较大partial由现有cost gate延后。问题因此不是partial/progress复用缺失，而是transport lifetime仍被Reader dispose统一截断。

### 编译/测试状态
- Trace不包含编译错误；当前执行环境无Flutter/Dart SDK，不能把Python静态gate当Dart编译或行为测试。
- dev.238回归正确冻结了consumer-bound transport必须在dispose前cancel+idle，但此前没有表达“某些transport capability本身独立于consumer close”的合法分支。

## 所有权清单

| 状态/资源 | dev.238 owner | 正确owner | dev.239处理 |
|---|---|---|---|
| physical partial / writer | composition `DownloadTransferOwner/DownloadSession` | 同左 | 不变 |
| logical demand claim | `DownloadTransferConsumer` | consumer scope | 不变 |
| active provider lease | physical NetLane task | physical task | 不变 |
| loader-backed controlled source capability | composition/source gateway，但经Reader投影 | composition capability，可被单task lease持有 | Reader仅暴露通用task-retainable resolver |
| Reader IO client/socket | Reader `_ioTransport` | Reader consumer | 明确禁止retained；dispose必须cancel+idle |
| transport lifetime判定 | 所有provider一律consumer-bound | transport capability自身 | sessions只消费通用bool-by-presence capability，不认识source类型 |
| progress | physical `DownloadSession.snapshot` | 同左 | 不变，不做synthetic progress |

## 被否决方案清单

- **让所有active transport跨Reader dispose存活**：会越过`IoTransport.close()`造成use-after-close风险，否决。
- **在sessions判断Venera/Mihon/external URL**：会把source实现泄漏进physical owner，否决。
- **把source gateway/loader registry复制到downloads**：制造第二provider registry与生命周期事实，否决。
- **复制partial到新Reader或logical exact session**：重建第二transfer owner，否决。
- **调低/调高full-body catch-up阈值**：只能改变何时付重复流量，不能修复无必要transport cancel，否决。
- **让duplicate bytes推动进度条**：继续伪造committed authority，否决。

## 结论

dev.238已把claim lifetime从admitted attempt拆开；dev.239继续把transport lifetime从consumer lifetime拆开，但只对能证明独立存活的transport capability开放。loader-backed controlled source可以由physical task独立持有，Reader-owned IO不能。这样跨Reader route的partial复用终于可保持同一个active writer，而sessions仍不承担source-specific知识。
