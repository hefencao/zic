# dev.267 根因审计：3/7 working-set churn 不应拥有 physical transfer cancellation

## 13:50 dev.266 真机设备事实

输入：`zic-debug-trace-2026-08-13T13-50-52.jsonl`。

- 9.606898s：current=99，`readDirection=+1`，3/7 body target落在100–106与96–98一侧。
- 9.701644s：Reader仅从99进入98。
- 9.702082s：下一policy revision立即变成`readDirection=-1`，新的7页前向落在97–91，后向落在99–101。
- 9.702194s–9.702454s：连续五个download identity记录`demandDetached`，对应旧前向边界page102–106整体退出working set。
- 本Trace没有`downloadPreempted`事件。因此当前最先要修的不是再扩大victim保护，而是把logical demand detach与physical task lifetime拆开，并让真正的scheduler cancellation有独立可观察原因。

## VibeVenera只读对照

`vibevenera-master.zip`中网络task与working-set迁移明确分层：running `StreamingDownloadTask`使用`retainWhenInactive=true`；active-key变化可取消queued工作，但不会仅因inactive直接取消running download。真正的slot竞争仍由task scheduler统一preemption处理。

其方向predictor包含candidate与weighted trend；后者在ZIC dev.266语境中反而暴露一个不适合直接迁移的细节：一次长dwell反向可让trend阈值先于candidateCount触发，所以真机99→98第一次反向就切向。dev.267只借鉴“方向是Pipeline状态”的owner结构，不复制该weighted trend阈值。

## 根因

1. dev.243已让active claim归零后降rank0，但NetLane只知道priority，不知道该active physical task是否仍有consumer claim。
2. dev.262为了no-Range连续性让已满足credit的response继续占active slot；normal work又不能随意preempt receiving，于是dev.264不得不把“flow已满足”误用成slot-reclaim资格。
3. dev.265再把Reader距离复制到NetLane保护near-two；dev.266又试图用方向减少detach。这些都是在下游补偿“scheduler缺少physical demanded state”。
4. 只要取消资格仍由flow target、Range或page distance推导，规则就会随着窗口/水位组合继续增加。

## 新owner模型

- Pipeline：working set、浏览方向、role、priority、flow credit。
- DownloadTransferOwner：consumer claims → physical `demanded`状态、stable task identity。
- NetLane：capacity、bucket、priority、restart-cost、`demanded`、single-flight preemption。
- DownloadJob：transport protocol、Range capability、body flow/backpressure；不决定normal slot victim。

## 明确拒绝

- 再加distance<=N保护；
- 再加turn grace/window union；
- 用flowTarget<=N推断可回收；
- 增加5路连接或扩大3/7；
- 把方向预测放进NetLane；
- 因旧gate字面量恢复dev.264/265 production字段。
