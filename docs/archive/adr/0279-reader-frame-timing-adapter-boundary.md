# ADR 0279：Reader FrameTiming 通过 presentation adapter 归一化

## 状态
Accepted

## 问题
dev.299为了观察明显纵排抖动的整帧cadence，直接在`ReaderView`注册`SchedulerBinding.addTimingsCallback`并读取`FrameTiming.timestampInMicroseconds(FramePhase.vsyncStart)`。用户本地真实Flutter编译首先报`FramePhase`未定义。单独补`dart:ui` import可以修符号，却会固化更深的边界错误：Reader业务Widget同时拥有Flutter engine timing API、订阅生命周期和Reader scroll语义。

## 决策
1. `reader`只公开框架无关`ReaderFrameTimingSource`、`ReaderFrameTimingSubscription`与`ReaderFrameTimingSample`。
2. `ReaderView`只订阅sample，把build/raster/total/vsync interval与自己的scroll/current/interaction关联后写Trace；它不得导入`flutter/scheduler.dart`、`dart:ui FrameTiming`或`FramePhase`。
3. `reader_runtime`作为Flutter presentation/observation adapter，唯一负责`SchedulerBinding.addTimingsCallback/removeTimingsCallback`与`dart:ui FrameTiming/FramePhase`归一化；`ReaderRuntimeScreen`注入该source。
4. source替换和Reader dispose必须幂等cancel；adapter不得请求额外frame，不得把timing写回Reader/Pipeline状态。
5. dev.299 `current±2` static presentation continuity是独立产品修复，本ADR不改变其eligibility、decode2/1或upload策略。

## 结果
Flutter API变化与Reader业务Widget解耦；Reader测试可注入fake timing source；具体engine符号只需在adapter层编译验证。若后续需要替换timing采集实现，不触碰Reader scroll/navigation代码。
