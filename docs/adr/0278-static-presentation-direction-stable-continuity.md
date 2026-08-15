# ADR 0278：静态 Presentation 使用方向无关连续性 envelope

## 状态
Accepted，设备效果待dev.299真机证伪。该决策不改变directional decode previous1/next2资源窗口，只修正已经存在的静态UI projection生命周期。

## 10:27设备证据
dev.298 Trace继续显示稳定Sliver布局与`staticWarmUploads=0`，但同一authoritative static frame仍会在后续可见时以`platformResidentReuse=true`再次presentation。代表page14首次作为current显示后，滚动到current13再到current12且`readDirection=-1`；此时page14绝对距离仅2，却因为directional previous1/next2窗口朝低index展开而从`currentPlan.decodes`退出。page14 host在整个区间保持mounted；稍后page14重新进入visible/transition后，同一个resident frame再次挂回。

这说明dev.298“仅当DecodeId仍在当前directional decode plan才保留projection”的合同仍让read direction拥有UI surface lifetime。两个方向的decode窗口各含current+3个邻页，但其方向并集是`current±2`。对已经成功显示的static surface而言，方向翻转不应令距离2的页面先整页清空再挂回。

## 决策
1. directional decode work继续严格使用previous1/next2；不得为了UI连续性新增DecodeDemand、扩大decode window或主动启动DecodeSession。
2. 已经存在且authoritative static的surface/PresentClaim可在presentation-only `current±2` envelope内跨directional decode-plan gap保留。这个envelope是两种directional 2/1 decode窗口的方向并集，不是新的prefetch窗口。
3. PipelineReaderSession只根据当前viewport current index、页面index与当前DecodeTarget重建“允许保留的同一DecodeId”；PipelinePageOutputStream仍负责验证surfaceIdentity、authoritative static与listener。该路径不得调用present。
4. 超出current±2、DecodeTarget/identity/generation变化、真实UploadState/output dispose或最后listener移除时立即释放。Animated output不适用。
5. dev.298对UploadDemand与projection lifetime的解耦保留；dev.297 pixel snap继续Superseded；dev.294–296稳定layout/upload/sourceCanvas证据继续冻结。
6. ReaderView同时增加真实Flutter `readerFrameTiming`观测，逐帧记录build/raster/total span、vsync interval及scroll/current/interaction。该telemetry不成为任何业务或scheduler输入。

## 可证伪条件
下一份设备Trace在current于N、N-1、N-2之间反复改变方向时，只要已显示static page仍处绝对距离<=2，不应再出现因direction flip导致的same-frame resident re-present或surface blank/reload。若该机械现象消失而肉眼仍有明显几十像素级抖动，以`readerFrameTiming`的frame interval/build/raster/total span判断是否为掉帧/cadence问题；不得再回到pixel snap、Sliver geometry或扩大decode窗口。
