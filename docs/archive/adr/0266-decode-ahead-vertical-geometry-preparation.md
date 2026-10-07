# ADR 0266：Decode-ahead vertical geometry preparation

状态：Accepted
版本：dev.287

## 背景

00:35 dev.286真机继续出现“缩放/比例需要稳定后才正常”。Trace证明尺寸事实并不缺失，而是到达Reader太晚：hidden next2在5.884986s已经decode出648×2328，page20在6.210488s成为current，而依赖output/UI的尺寸路径到6.227453s才可用；另一页6.255154s已decode 608×2232，6.611259s成为current，6.638313s才进入output路径。dev.281主动延迟active-scroll hidden next2 texture upload，使把geometry尺寸绑在output/presentation上的延迟更明显。

## 决策

- DecodeSession generation保存首个成功frame的`decodedWidth/decodedHeight`；该字段只是decode事实，不拥有Reader layout。
- DecodeRegistry把真正frame-ready时的snapshot投影给Pipeline；PipelineReaderSession按PageAsset稳定identity发布只读`pageDimensions`，并在retained Reader session内保存该事实。
- ReaderRuntime仍是`pageAspectRatios`唯一projection owner；它消费Pipeline dimensions并复用既有`_reportPageDimensions`，PageAsset intrinsic width/height仍优先。
- vertical active scroll仍冻结所有会改变当前viewport前缀的geometry。ReaderView只可立即采用**真实visible tail之后**的最新ratio，因为这些future item extent不会改变当前pixels对应的prefix；visible tail及之前的ratio继续latest-wins pending并在idle由dev.281 layout correction提交。
- dev.286的独立visual presentation extent、OverflowBox裁切workaround退出production。媒体继续填充Reader提供的等比page box；目标是页面可见前geometry已被decode-ahead事实准备，而不是页面可见后在错误box内做视觉补偿。

## 不变量

- 不改变previous3/next7、decode2/1、holder7/5/3/2、normal5+current reserved1、dev.281 hidden-next2 upload deferral或dev.285 promoted hot retention。
- Pipeline dimension metadata不得成为download/decode admission输入。
- active scroll不得提前采用visible tail或其之前的ratio。
- retained Pipeline session允许Reader re-entry立即重放已知dimensions，但不得建立第二套geometry owner。
