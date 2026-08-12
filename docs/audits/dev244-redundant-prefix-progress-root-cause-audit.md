# dev.244 redundant prefix / progress 根因审计

## 问题清单

- 编译错误：当前设备Trace没有编译错误证据；工具链验证状态见release validation。
- 产品错误：同一verified-equivalent图片虽然已共享physical partial，但切换logical版本/current后仍可通过active-provider handoff主动取消已admit provider；回页时`committedLength`长时间不增，单进度条无法辨别正在重读旧prefix还是没有获得网络执行。
- 性能问题：09:47 Trace共10,000条事件，`duplicatePrefixBytes`合计55,743,710：full-body catch-up 44,741,284，catch-up aborted 10,412,602，validatorless overlap 589,824。两次provider handoff均仅发生在shared physical owner内部。
- 测试错误：dev.237/238/240/241历史gate把“provider exact replacement必须由rank触发”冻结为永久源码形状；dev.244起必须改为版本感知，保留NetLane slot rank合同而删除provider request churn合同。
- UI缺口：旧Reader双层solid bar实际是`networkStartLength`+`committedLength`，没有真实transport cursor；无法观察Range→200 replay、attempt reset或当前速率。

## 所有权清单

| 状态/资源 | 正确owner | dev.244 |
|---|---|---|
| verified-equivalent partial / writer | physical `DownloadSession` | 唯一且monotonic |
| network slot / preemption / restart retention | `NetLane` | 统一rank，不知道provider版本 |
| admitted provider exact URI / transport | active task lease | task lifetime稳定；logical rank变化不替换 |
| provider consumer close | transport capability | consumer-bound硬取消；task-retained可越界 |
| transport current cursor | `DownloadSession` transient projection | `DownloadJob`唯一写，非durable |
| Reader partial line | Pipeline→Reader只读projection | `committedLength`直线 |
| Reader current wave | Pipeline→Reader只读projection | network cursor + Vibe速度色 |

## 被否决方案

- 再调provider takeover rank margin：否决。shared physical bytes已经verified equivalent，切exact provider本身不是slot竞争。
- current切换时强制provider URI同步：否决，会主动丢弃已经支付的full-body replay/连接。
- 把duplicate bytes加到`committedLength`让进度看起来增长：否决，会伪造authoritative partial。
- UI按cancel/preempt事件自行维护第二份进度：否决。transport cursor必须来自physical session唯一事实。
- 动画波浪表示“活跃”：否决。波浪只表示当前transport byte cursor，静态形状不伪造无字节增长时的活动。
- 直接照搬VibeVenera owner/cache：否决。只采用其Reader current progress的speed smoothing与红/amber/绿视觉语义。

## 结论

dev.244把scheduler rank重新限定为physical task slot竞争；provider exact从policy变量恢复为admitted task lifetime事实。与此同时新增transient transport cursor，使UI第一次可以区分“authoritative partial已经到这里”和“当前连接实际读到这里”。因此后续若仍出现长时间不增长，可直接判断是prefix replay、真实NetLane preemption、consumer-bound close还是无transport progress，而不再通过单条partial进度猜测。
