# dev.300 Reader FrameTiming 边界审计

## 触发
用户本地编译dev.299时报`packages/reader/lib/src/reader_view.dart`中的`FramePhase.vsyncStart`未定义，并要求重新审查代码边界、解耦和收口。

## 审查
- `ReaderView`原本直接import `package:flutter/scheduler.dart`、注册/退订`SchedulerBinding`并解析`FrameTiming`。这些代码仅服务性能诊断，不属于Reader navigation/layout的业务所有权。
- Reader内其他`WidgetsBinding.addPostFrameCallback`主要负责其自身layout/anchor/navigation提交，不能因为本次错误一并抽走；应只移动engine timing adapter边界。
- `pipeline_native`已有`PipelineFrameScheduler`的Flutter adapter，但Reader反向依赖Pipeline native会破坏包依赖方向，因此不能复用为FrameTiming source。
- `reader_runtime`本来就是Reader与Pipeline的Flutter presentation/observation adapter，并且是production中唯一构造`ReaderView`的位置，适合作为FrameTiming具体实现owner。

## 收口
新增framework-neutral timing source契约到`reader`，具体Flutter adapter放`reader_runtime`。ReaderView不再知道`FramePhase`或`SchedulerBinding`，只处理归一化sample与自身scroll上下文。production由ReaderRuntimeScreen注入；直接Reader widget tests可不注入或使用fake source。

## 验证重点
本地Flutter编译必须首先闭合原`FramePhase`错误；随后真机Trace应继续产生`readerFrameTiming`，且dev.299 `current±2` presentation continuity、`staticWarmUploads=0`、decode previous1/next2均保持不变。
