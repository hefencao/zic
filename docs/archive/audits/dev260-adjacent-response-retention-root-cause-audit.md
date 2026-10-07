# dev.260 根因审计：相邻页水位满足错误关闭 response

## 设备证据

09:00 Trace 的 page99 给出直接时间线：

- 作为next1时已有491,520-byte partial，`flowTargetFrames=5`；
- 8.724s进入`pseudo-paused`，8.840s进入`pseudo-suspended`，8.855s记录`flow-satisfied completedFrames=5`；
- 8.939s仅移动一页成为current；
- 8.944s同physical identity再次`downloadStarted`，`committedLength=491520`。

间隔约104ms。期间没有`downloadPreempted`、partial reset、failure或physical generation替换。因此重开是consumerPacing suspension主动结束response造成，而不是NetLane 5路淘汰。

## 为什么5个连接以前反而“保留更多”

`maxActive=5`只限制同时active的network body task，不限制hot partial数量。旧的unlimited/pseudo-drain阶段会让若干response长期存活，composition registry又可独立保留更多partial。dev.259让bounded flow真正生效后，dev.254的“positive target满足即关闭unsupported response”开始频繁触发，导致warm response数量反而下降到0，而不是受5路上限自然控制。

## 所有权收口

- frame target：Pipeline policy；
- response是否值得短期保留：同一Pipeline role policy，用`retainFlowResponse`投影；
- transport是否支持真实backpressure：`ByteResponseFlowControl`；
- partial/frame proof：physical DownloadSession/TransferOwner；
- active connection容量：NetLane。

不允许由frame proof、committed bytes或transport capability自行推导页面是否“热”。

## 被否决方案

- 提高normal连接数：掩盖response被主动关闭的根因；
- 整个3/7都恢复pseudo-drain：重新造成远端流量持续越过水位；
- 按committedLength/restart-cost保护相邻页：把内容事实重新混入角色policy；
- 新增时间grace后才关闭：对“是否相邻”已有确定角色事实，不需要再发明时间阈值；
- 半实现paused connection pool：没有resume permit arbitration会突破并发边界。
