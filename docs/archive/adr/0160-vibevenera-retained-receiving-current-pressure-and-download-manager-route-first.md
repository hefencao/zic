# ADR 0160：VibeVenera Retained Receiving、Current Pressure 抢占与下载管理 Route-First

状态：Accepted
版本：0.31.0-dev.177

## 背景

新 Trace 证明 dev.175/176 的 transport cancellation、native source-lock缩短与 CRC热路径迁移有效，但 current仍可能在 Venera/source-plan层等待。最初候选曾把“离开 encoded 7/3窗口”直接解释为必须取消 active download；重新只读对照权威 `vibevenera-master.zip` 后确认这是退优化：VibeVenera明确区分 logical detach 与 physical eviction，已经 `receiving` 的 transport在普通窗口脱离时继续存在，queued/未开始工作则取消；真正的 current竞争到来时，scheduler才按 priority抢占低 rank receiving。这样前后快速切页不会反复断线/重下。

ZIC 比 VibeVenera多一层 Venera单上下文 runtime gate。仅依赖 NetLane抢占可能取消到另一个 HTTP task，而真正持有 Venera JS上下文的低优先级 invocation仍挡住 current，因此同一 pressure-preemption原则还必须下沉到该唯一 runtime permit。

另一个独立问题是首页点击下载管理后数秒才出现页面：旧 `DownloadManagerScreen.initState()`在下一帧前通过 microtask启动 whole-queue ready、逐章节 durable inspect与 cache检查，route首帧被后端初始化抢走。

## 决策

1. **Logical detach保留 receiving。** DownloadDemand离开 encoded窗口时，如果 task正在 active receiving，则只迁移为 `retained-background=0`；queued task可以取消。已经接收的 transfer不因为普通前后翻页立刻断线。
2. **真正 current pressure才抢占。** NetLane继续保留 current=1000、priority migration、threshold=40、normal5 + reserved1。handoff已占满时新的 current仍可请求另一个尚未cancel的最低rank victim退出，但真实permit只在原task结束后释放。
3. **Venera唯一permit执行同样规则。** scheduler-controlled active invocation若优先级明显低于后到 current，则 runtime gate请求取消该 active request并把唯一permit转给最高优先级 waiter；普通 detach本身不触发 runtime cancel。`runtime-request-cancelled`映射为 domain `ErrorCode.cancelled`，无 demand retained task不重启；仍有 demand的 prefetch可由既有协调器后续重新调度。
4. dev.175 的 TaskControl贯穿 source/runtime、dev.176 的 full-response abort与 checksum off-hot-path继续保留。
5. `DownloadManagerScreen`首帧直接消费 Home现有 chapter snapshot与 whole-comic queue snapshot；`ready`、durable bulk inspect和 cache usage只允许在首帧后执行。
6. durable chapter刷新使用 `ChapterDownloadService.inspectMany()`，不得在route init阶段逐entry创建 `inspect()` future。

## 边界

- 只有显式 cache clear、Reader dispose/session eviction等 physical eviction动作才无条件取消 undemanded receiving；普通 page-window detach不是 physical eviction。
- 保留 partial artifact/resume语义，但不依赖“反复cancel再resume”作为普通翻页策略。
- 不扩大 Venera并发；仍为单 invocation context。
- 不修改 7/3、2/1、holder 7/5/3/2、network/decode/upload 5/3/2。

## 验证不变量

- current→next→current的短时往返，在同一 receiving transfer未被真实current压力抢占时必须保持同一task/connection，`opens`不得增加。
- receiving task离开窗口后priority可降到0；再次进入窗口时必须原位升回当前priority，而非新建第二个writer。
- 当current在NetLane或Venera单上下文上真实受阻时，低rank receiving可被抢占；handoff/permit只有真实退出后释放。
- 下载管理的durable refresh即使被测试fixture永久阻塞，route第一帧仍必须已经显示Home投影的下载项。
