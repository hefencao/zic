# dev.204：retention回滚幅度与Venera cold plan根因审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.203_bounded-restart-cost-retention-rollback.zip`。

## 11:48真机证据

- trace约1.75MB / 5541 events；20次firstFrameReady中位约70ms，p90约1.56s，最坏约2.33s。
- 30条origin body中request-plan cache miss 21、hit 9；miss plan中位约1.34s，hit中位约0.014ms。
- current=1000的3个典型miss plan约1.83s/0.99s/0.78s；其gate wait约55ms/11ms/近0，说明current physical preemption仍有效，cold tail主要属于自身resolver work。
- cold current首次resolver可出现4次bridge origin call；随后相邻locator通常变为3 cache hit + 1 origin，说明dev.191 cache有效但无法消除首次shared resolver数据获取。
- dev.203 preemption churn约1.24次/秒；用户确认dev.203回滚幅度过大。6.84s dev.202最坏首帧已被上一轮审计定位为source-plan/host-open而非current被retention阻塞，因此不应把headroom全量撤回。

## 源码根因

`VeneraNativeBridge.httpWithUrlConnection()`此前在正常完整response之后仍无条件`connection.disconnect()`。resolver的`loadThumbnails/getKey/page API`等逻辑Network调用由单JS invocation顺序执行；主动disconnect会丢失刚建立连接的可复用机会。当前cache identity/cookie规则与single-invocation无需改变。

## dev.204收口

- retention恢复为dev.201 bounded与dev.202 headroom之间的2/3-headroom插值，等价于相对dev.202只回滚约1/3；1000 current的40点margin保持。
- Venera完整response显式关闭InputStream后不再主动disconnect；异常/取消仍disconnect。
- 不改Venera并发、request-plan cache identity、Network control headers、Reader/Pipeline、Range/defer、network=5。

## 下一轮验证

重点比较cold `sourcePlanBridgeNetworkMicros`、首次4-origin current的plan耗时、first-frame p90/max，以及`downloadPreempted`中base=0高成本task的retention分布。若bridge origin仍长尾，再继续拆DNS/TLS/服务器响应；不得据此增加JS并发。
