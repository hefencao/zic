# dev.240 current provider reclaim root-cause audit

## 问题清单

- 编译错误：本轮设备Trace无编译错误证据；当前环境仍需依赖静态门禁，Dart/Flutter工具链状态另见validation。
- 产品错误：跨新旧版本切换后current logical demand已为1000，但active provider exact可继续停留在旧Reader generation。
- 性能问题：旧provider可能继续执行与当前版本不一致的request/resume路径，current无法用自己的exact provider即时接管；这会放大source-open、Range/full-body fallback长尾。
- 测试错误：dev.238/239回归把“所有orphaned provider均不得handoff”冻结得过宽；需要保留普通orphan retention，同时允许high-priority reclaim。

## 设备证据

- Trace共4553条事件，`downloadPriorityChanged` 129次、`downloadPreempted` 13次，证明NetLane preemption与priority migration真实存在。
- 多次新Reader current demand把既有physical task提升到1000；其中physical identity在reader-2/reader-3仍由reader-1 provider lease服务。
- `active-provider-handoff`为0，说明阻断点位于provider lease规则而非NetLane slot admission。
- NetLane源码确认queued/active priority上升都会调用`_pump()`；因此不增加Reader侧cancel或第二scheduler。

## 所有权清单

| 状态/资源 | 当前owner | dev.240正确owner/规则 |
|---|---|---|
| physical partial/writer | `DownloadSession` | 不变，handoff不得替换 |
| network slot/priority/high-priority class | `NetLane` | 不变，并公开通用`isHighPriority()`分类 |
| logical exact demand | `DownloadTransferConsumer` claim | 不变 |
| active provider exact/transport | `_ActiveProviderLease` | ordinary orphan可retain；different-exact high-priority preferred可reclaim |
| Reader role语义 | Pipeline demand policy | sessions不得识别`current`名称或硬编码1000 |

## 被否决方案

- Reader切版本时直接cancel旧下载：否决，会重新建立UI调度authority并破坏single NetLane。
- 恢复dev.237“任何orphan都handoff”：否决，04:46证据已证明会白白丢弃已支付full-body catch-up。
- `priority == 1000`硬编码：否决，high-priority分类属于NetLane配置。
- current显示synthetic progress：否决，不解决provider/request authority。
- 为新版本复制partial或创建第二physical task：否决，违反single physical owner。

## 收口

本轮只补齐“scheduler authority迁移后provider authority也必须在high-priority different-exact场景迁移”这一条。普通orphan retention、task-retained transport、same-exact reuse、restart-cost retention与full-body admission继续保持。
