# ADR 0287：Local static pre-presentation 与 reverse geometry preparation

## 状态
Accepted for dev.308；等待真机证伪/闭环。

## 问题
04:45 dev.307 Trace显示两个此前被统一“active scroll冻结”策略误伤的本地图片边界：

1. 已经处于既有stable decode窗口、encoded body由本地/持久不可变authority持有且decoder已确认static的页，仍被dev.295 generic hidden-static UploadDemand deferral阻止首次presentation。host与decode可能提前准备，但页面成为真实transition后才开始platform present，产生约50ms loading/黑屏。
2. active vertical ratio冻结只允许`visibleMax`之后的future ratio提前采用。向lower index快速滚动时，incoming页位于viewport prefix，sourceCanvas即使早已解析也保持one-screen provisional extent，直到idle才切真实extent，造成明显重排。

## 决策 A：本地/durable authoritative static 可提前 presentation
Generic/network/unresolved hidden static继续遵守dev.295 active-scroll deferral。

只有同时满足以下条件的stable static page可在active vertical中提前UploadDemand/present：

- page已经位于既有stable decode/static warm窗口；
- decoder authoritative animation classification为`animated=false`；
- encoded body由direct immutable local URI（file/content/asset）或当前physical DownloadSession的`residentBodyBacked` immutable authority持有；
- 仍服从既有static output budget与FrameBudgeter。

该例外不得：

- 新增DecodeDemand或把stable decode从previous1/next2扩大；
- 扩大encoded 3/7；
- 应用于animated、unresolved或普通network hidden page；
- 建立新的cache/session/texture owner。

提前完成的static output在既有budget内`retainOutput=true`，使page进入transition前presentation-ready。

## 决策 B：reverse future ratio以layout-time anchor correction提前采用
active vertical geometry按travel direction区分安全的future ratio：

- `travelDirection > 0`：仅严格高于`visibleMax`的future页可立即采用；它们位于当前painted prefix之后，不改变当前top offset。
- `travelDirection < 0`：仅严格低于`visibleMin`、尚未真实可见的incoming页可立即采用；它们改变viewport prefix，因此Reader必须在同一次new-dimensions layout通过`geometryCorrectionTarget = nextGeometry.restoreTop(oldAnchor)`原子补偿ScrollPosition。
- 当前真实visible页ratio仍冻结，idle时按既有latest-wins + anchor correction一次提交。

不得恢复post-frame ratio `jumpTo`、插值/平滑、presentationExtent workaround或ScrollPhysics参数调优。

## 理由
两项变化都属于“进入viewport之前完成已经权威可知的准备”，而不是扩大资源/布局推测：static性质与local body authority由现有owner确认；ratio来自physical sourceCanvas。这样可以在不改变窗口和当前visible geometry的前提下消除本地页首次可见黑屏与reverse first-pass provisional extent重排。

## 真机判据
- 对local/durable static incoming page，`framePresented/firstFrameReady`应发生在其成为真实transition之前或至迟同一帧，不再出现约50ms visible black gap。
- generic/network hidden static在active vertical仍保持dev.295 deferral。
- reverse incoming页若sourceCanvas已提前解析，first-pass layout必须直接使用measured extent；visible top不得因prefix变化跳动。

Historical owner token: `localPresentationReady`.
## dev.314 设备证据修订

dev.308 的 reverse geometry 决策继续 Accepted；但“authoritative local static 可在 active vertical 中隐藏 pre-present”的例外被 dev.314 **Superseded**。10:26 真机显示 off-screen `mediaClassified(localPresentationReady=true)` 可在固定内容边界 force replan，并启动 `next2` SurfaceProducer blit；具体 page11 的 712x2336 blit 为 16.163ms，紧邻 32.845ms scroll cadence gap。故 local/durable static 只可在 idle 或成为 current/transition/真实 visible 后 upload；active 时仍保留 decode warm。
