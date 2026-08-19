# dev.308 Local static pre-presentation / reverse geometry audit

## 基线与触发
- 唯一代码基线：`zic_v0.31.0-dev.307_reader-position-lifecycle-boundary.zip`。
- 真机Trace：`zic-debug-trace-2026-08-19T04-45-20.jsonl`。
- 用户现象：所有页面均为本地图片；滚动中部分页面短暂loading/黑屏，快速滚动还会在图片加载后重排。

## 黑屏证据
后段快速向higher index滚动时：

- page19 host约38.115s已mount；38.554s首次成为真实transition，约38.580s才完成frame presentation，38.605s `firstFrameReady`，可见空窗约51ms。
- page20 host约38.424s已mount；39.247s成为transition，约39.271s presentation，39.299s `firstFrameReady`，空窗约52ms。
- 对应静态page的encoded body来自immutable local/durable authority；decode可早于viewport边界完成，但dev.295 hidden-static active deferral仍把首次UploadDemand/present推迟到真实transition。
- Android expensive native blit运行在texture bridge专用单线程executor，不是Android main thread；因此本轮不把“main-thread blit”作为根因，也不据此调整platform thread。

## 重排证据
RenderBox本身始终服从Reader geometry（`extentDeltaPx=0`），重排来自geometry owner先使用provisional extent、后提交真实ratio：

- page17 physical sourceCanvas 960×3450约11.857s已解析；约12.969s首次pass仍使用`expectedExtent≈924.44px`，后续使用`≈1533.23px`。
- page19 sourceCanvas 960×3225约10.525s已解析；第一次相关pass仍可见`≈924.44px` provisional extent，后续为`≈1433.28px`。
- 原`_adoptFutureVerticalRatios()`只采用`visibleMax+1...`，因此只对higher-index travel天然安全；lower-index incoming页处于viewport prefix，被错误冻结到idle。

## 所有权审查
### Presentation
- `HeuristicPolicy`仍唯一决定UploadDemand。
- `PipelineController`只保存decoder/runtime fact：`runtimeAnimatedPages`与`runtimeLocalStaticPages`。
- `PipelineReaderSession`只在decoder authoritative animation result到达后判断local presentation readiness；不从URI hint单独推断static。
- `runtimeLocalStaticPages`不会创建额外decode；只解除local authoritative static页的hidden upload deferral，并让其已有static output在既有budget内retain。

### Geometry
- `PipelinePageDimensionsFeed`/physical sourceCanvas仍是ratio fact owner。
- Reader只在页仍完全位于incoming future区域时采用ratio。
- lower-index prefix变化由Reader已有layout-time ScrollPhysics correction seam原子吸收；current/visible ratio不在active scroll中直接切换。

## 明确未改变
- encoded previous3/next7；decode previous1/next2；holder 7/5/3/2；NetLane normal5 + current reserved1。
- generic/network/unresolved hidden-static active upload deferral。
- sourceCanvas authority、MediaAspectViewport、texture bridge、FrameBudgeter owner。
- dev.307 command/current projection与bounded current±7 keepAlive center。

## 证伪条件
- local incoming static仍在transition后几十毫秒才firstFrameReady：继续查classification→UploadDemand→present admission，不扩大window。
- reverse first-pass已使用真实extent但仍发生位置跳变：再检查geometry correction的layout-time原子性；不得回到post-frame jumpTo。
