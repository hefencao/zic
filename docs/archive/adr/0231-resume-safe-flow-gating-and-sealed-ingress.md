# ADR 0231：resume-safe frame gate 与 sealed ingress 幂等长度确认

状态：Accepted

## 问题

dev.251 23:17真机Trace同时暴露两类生命周期错误。其一，late Reader synchronized replay可先把native source seal，再由同一attachment路径重复`expectLength`；native capacity reserve在sealed source上返回sealed，Ingress把该状态升级为source failure，导致图片无法decode。其二，frame gate初始化时从authoritative artifact统计已有ANMF帧，但新network attempt可能仍从0或overlap位置追赶该partial；旧实现会在network cursor尚未到达existing committed boundary时按旧帧数pause，形成resume自锁。Trace还出现两次rhttp direct长hard-pause/resume后的`StreamSink is bound to a stream`。

## 决策

1. `Ingress.expectLength`把sealed+同实际长度视为幂等确认，不再调用`ExpectedLengthEncodedSource.reserveExpectedLength`；sealed后长度不一致直接报告artifact corruption，但不得disable既有source。
2. `_WebpNetworkFlowGate`在每个attempt创建时冻结`authoritativeCatchupFloor=session.committedLength`；当`networkCursor < floor`时frame credit不得阻止读取。只有network追到已有partial边界后，authoritative completedFrames才可限制新增speculative body。
3. `ByteResponseFlowControl.consumerPacing`不再等同无限consumer hold。blocked时每100ms最多放行一个chunk并记录`pseudo-drain`；credit变化可立即唤醒并`pseudo-resumed`。这保持同一task/response/physical writer，同时不把unsupported pause变成cancel/reopen。
4. rhttp direct改声明`consumerPacing`。Dart HttpClient direct继续声明`streamBackpressure`；artifact-cache/resident保持快速本地路径。
5. 本ADR不修改3/7、5/3/2/1帧水位、NetLane 5+1、provider/partial/progress ownership，也不半实现paused-connection pool。
