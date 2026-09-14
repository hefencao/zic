# Reader re-entry speculative-budget bootstrap audit — 2026-09-14

## Observation

Reader双向性能复核确认3/7 download window、2/1 decode window与真实手势target的priority-820 frame0 preupload均正常，但re-entry后的第一个next页存在异常长的source等待。hot partial样本已有约6.46MiB authoritative physical prefix，physical retained response也已立即重新attach，frame0仍出现6,697,878us `sourceWaitMicros`；另一个durable promoted resident样本从priority820开始0..256KiB hydration，到手势把target提升为priority900后才完成，frame0 `sourceWaitMicros`为1,807,609us。两者native decode本身只在几十毫秒量级。

## Ownership finding

阻塞点不是网络、storage read吞吐或decode，而是composition-owned `SpeculativeEncodedReadBudget`。25MiB背景预读取上限已被旧3/7 speculative accounts占满，Reader-local hot artifact replay和durable resident replay又消费同一gate，因此一个新projection即使physical bytes已经存在，也无法取得建立decoder source所需的首个local quantum。priority900会按既有合同foreground-bypass，于是问题只在真实手势到来后突然解除。

这属于liveness缺口而不是提高预算即可解决的问题：预算拥有background read-ahead threshold，但不应让较早speculative work永久阻止一个新Reader consumer从已经存在的physical authority建立最小decoder ingress。完整绕过budget又会重新引入无界本地预读，所以例外必须严格有界。

## Repair

`CompositionDownloadTransferRuntime`现在对Reader-local WebP首次decoder bootstrap统一提供一个bounded read credit：

- nonresident hot partial仅在`start == 0`且provider chunk不超过WebP decoder probe quantum时获得首个credit；
- durable resident / artifact-cache / direct local replay仅对首次`0..256KiB` range获得首个credit；
- 首个quantum仍经唯一`ArtifactCacheReadScheduler`，只是不会因旧speculative charge已到threshold而在读前无限等待；
- bytes读取后仍记入同一`SpeculativeEncodedReadBudget`，threshold最多超调一个256KiB decoder quantum；
- 第二个及后续quantum恢复普通budget gate；
- 不授权network source growth，不改变3/7、NetLane、priority、DecodeDemand、UploadDemand或waterline。

focused regression分别覆盖hot partial和resident immutable body：budget已被另一account填满、priority820时，首个256KiB必须可发布；第二个256KiB必须继续阻塞，直到priority升到900。

## Device validation

最新profile安装后，trace `.log/zic-debug-trace-2026-09-14T00-17-05.jsonl`给出直接证据：

- page370在page369 current期间以next身份建立，download priority=820；
- resident hydration `0..262144` 于22.529309s开始、22.540784s完成，仅11.475ms；
- page370 decode frame0于22.944499s完成，`sourceWaitMicros=0`、`nativeDecodeMicros=59,720`；
- 首个真实page transition到24.471805s才发生，因此frame0提前约1.527s；
- 369→370 `mountToFirstFrameMicros=42,688`；
- 非current frame pipeline仅出现target next frame0，UploadDemand priority=820；
- task failure=0；设备`readerPrefetchReadBudgetMiB=25`、battery saver关闭。

因此本轮修复不是放宽预取窗口，而是让已有physical bytes能在budget饱和时完成一个最小Reader-local decoder bootstrap，同时保持后续读放大仍受原composition budget约束。

## Steady playback follow-up

在bootstrap修复后的同一profile APK上又采集了无翻页Reader样本 `.log/zic-debug-trace-2026-09-14T00-25-04.jsonl`。最新Reader session从`t=469.439663s`到`t=511.660231s`，覆盖42.22s；首帧后持续窗口约42.04s。

持续播放没有出现需要继续改媒体链的证据：106个`framePipelineTiming`中native decode p50=43.072ms、p95=50.455ms、max=62.398ms，均明显低于125ms frame duration；41次`playbackFrameDue` lateness p95=1.883ms、max=1.919ms，0次超过8ms且`successorBuffered`始终为true；42次`framePresented`均`awaitingSuccessor=false`，successor depth最低3、中位7。source wait p95=0、max10.828ms；20次resident hydration p95=47.751ms、max50.299ms。session内`taskFailed=0`、`error=0`。

14次`retryScheduled`全部属于`stage=decode-prefix`的正常need-more-data增量扩源，不是网络retry。唯一`sourceRead`属于后台retained HTTP response；其约442s body gap反映park/resume生命周期，而不是current播放持续阻塞。另有一条Flutter `totalSpanMicros≈200,388`，但build=148us、raster=3,899us、vsync overhead约196ms；同窗texture playback deadline仍正常，因此不能据此修改decode/upload/raster/刷新率策略。当前结论是steady Animated WebP media path健康，后续只有出现新的真实deadline miss / awaiting-successor / source-stall证据时才重新打开该方向。
