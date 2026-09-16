# ADR 0315：纵排快速静态首帧与方向翻转 working-set 边界

## 状态
Accepted。

## 问题
external-static 恢复3/7 one-frame intent后，普通速度可在进入viewport前约2秒完成首帧，但快速连续滑动会追上单路 speculative external presentation。另一方面，完整3/7都出现Decode/Upload intent后，active download bridge把“所有decode/upload都有source需求”解释为全部mandatory，方向确认时一次替换5个DownloadDemand，重新制造单turn working-set翻转。

## 决策
1. `LiveCoordinator`通用缺省仍只允许1个offscreen speculative external-presentation pending；Reader stable profile显式允许最多3个。真实`viewportVisible`、current、transition不计入该speculative cap并继续拥有抢占资格。该cap不改变3/7 DownloadDemand、2/1近邻语义、NetLane、50MiB encoded actual-read budget或Flutter ImageCache owner。
2. active vertical download bridge的mandatory source只包括current、transition、真实viewport以及current/next/next2/previous既有近邻media角色。far static one-frame Decode/Upload intent不能把其DownloadId升级成mandatory；只有其source identity被bridge纳入后，对应Decode/Upload才保留在accepted plan。
3. bridge保留的是physical/source identity，不保留旧semantic role；shared identity必须采用当前desired DownloadDemand role，禁止旧current在下一observation中残留成第二current。
4. direction flip时far encoded/static working set继续按每个committed current最多推进一个desired identity；idle/scrub/jump仍完全收敛canonical 3/7。
5. `DownloadTransferOwner`把consumer的logical→physical/version/canonical resolution视为acquire-time state。仍在同一consumer demand set中的logical `DownloadId`只做role/priority metadata迁移，不重复resolve；只有新进入的logical identity重新解析。identity/proof/completion intent变化仍走完整authority path。
6. offscreen exact external-static不再要求PageHost先挂载才具备presentation consumer。Coordinator仍选择exact grant和3路Reader cap；App composition只注入detached presentation executor，消费既有generation-scoped presentation file/bytes capability，把第一帧写入现有Flutter ImageCache并回报同一grant。它不得建立隐藏Reader/Page widget、网络/重试/cache authority或第二raster cache；挂载后的`LocalImagePlayer`用同一generation/cache identity命中该帧。当前实现仅在source raster无需layout-specific `ResizeImage`时执行detached warm，超出physical viewport的页面保守回退mounted path，避免预热错误cache key。

## 设备判据
`zic-debug-trace-2026-09-16T01-32-51.jsonl`：方向确认发生5加5删，reconcile 8.158ms（120Hz整帧预算8.333ms），bridge未介入；external request→first-frame p95 520ms、max1.218s。

修复后Profile `zic-debug-trace-2026-09-16T02-08-52.jsonl`：direction flip为1加1删，`big_5x5=0`，bridge事件336次，flip reconcile 6.217ms；external request→first-frame p95 283.7ms、max552ms；active scene interval无>=35ms样本，taskFailed=0。

用户手测导出 `zic-debug-trace-2026-09-16T05-44-48.jsonl` 又暴露两处后续成本：current-boundary reconcile中位9.880ms、7/7超过3ms，direction flip重新表现为5加5删/16.382ms。后续收口physical resolution与bridge后，fresh Profile `zic-debug-trace-2026-09-16T07-04-58.jsonl` 的current-boundary reconcile中位1.245ms（downloads 0.628ms），flip为1加1删/4.015ms；detached external-static prewarm 76次started、76次prepared first-frame、0 failure，直接配对start→prepared p50 40.2ms/p95 53.4ms/max67.5ms。35个进入真实visible集合的页面中32个已提前ready，仅启动附近144–146三页在visible后74–150ms出帧；71次mounted visible frame明确消费`prepared=true`。platform interval >=35ms为0，active-scroll WindowMetrics无outlier，taskFailed=0。近期真实presentation raster主要为720×700（另少量720×662），均在当前detached exact-key支持范围；尚无证据要求扩展到layout-specific ResizeImage key。
