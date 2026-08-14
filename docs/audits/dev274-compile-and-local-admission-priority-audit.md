# dev.274 编译闭包与 local admission priority 审计

## 设备事实

04:00 Trace 初始 current=106：policy先下发 current priority=1000，随后820/800/780/...；但local miss约11–13ms异步结束后，network task实际先创建820、760、740，current1000第四个进入source/runtime路径。当前页mount→first-frame约3.35s；另一cold current page303约4.22s。Venera request-plan仍显示明显单invocation gate长尾，但其runtime gate本身已具priority/preemption，不能通过增加JS并发修复。

## 源码根因

`_startLocalPreparation().whenComplete()`直接`scheduleMicrotask(_ensureDownloadTask)`，因此dev.272正确的pre-NetLane local I/O解耦意外把scheduler ordering权交给了local I/O完成时序。与此同时dev.273 direct metadata parser误用了不存在的`Validators.isNotEmpty`，形成真实本地编译失败。

## dev.274 收口

- validator scope判断改为真实transport契约`Validators.canResume`。
- local prepare仍可独立并行；完成后进入`_preparedNetworkAdmissions`，不直接创建NetLane task。
- 任何lower-priority ready work若存在higher-priority demanded local preparation，记录`post-local-network-admission/deferred-by-higher-local-priority`并等待；higher完成后按当前`DownloadSession.effectivePriority`排序后交给NetLane。
- 该层不拥有network容量、victim或Venera invocation permit；这些继续分别属于NetLane与runtime gate。
- 未改变previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1或Venera `maxConcurrentInvocations=1`。

## 后续设备判据

初始/冷切页时，priority1000 local prepare未结束前，820/800/...的post-local ready任务不得先`downloadStarted`。若current已第一时间进入source path但`sourcePlanRuntimeInvocationMicros/sourceHostOpenMicros`仍主导数秒延迟，再单独处理source-plan冷启动，不应回头调整NetLane或local partial边界。
