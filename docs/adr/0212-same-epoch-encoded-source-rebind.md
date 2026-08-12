# ADR 0212：Same-epoch encoded source replacement invalidates decode cursor

- 状态：Accepted
- 日期：2026-08-12
- 版本：dev.232

## 背景

`DownloadIngressProjection.rebuild()`会调用`Ingress.reset(epoch)`并在随后append时创建新的`EncodedSource`。rebuild可以保持同一`SourceEpoch`，因此epoch只证明下载内容世代，没有证明Reader-local native source handle仍是同一个对象。

dev.231设备Trace出现3次`partial-source` decode `taskFailed`：失败时projection显示未sealed且随后source增长可正常出帧。审计发现`DecodeSession._bind()`只按epoch复用cursor，所以同epoch source replacement后可能继续使用绑定在旧source上的cursor；snapshot与decode实际source因此分裂。

## 决策

1. `DecodeSession`显式记录当前cursor绑定的`EncodedSource`实例。
2. cursor复用条件必须同时满足：已有cursor、`SourceEpoch`相同、`EncodedSource`实例identity相同。
3. 同epoch但source实例改变时必须释放旧cursor/holder并从当前authoritative projection重新绑定。
4. partial-prefix restart与普通release必须同步更新该binding identity，不允许出现cursor与bound source分离。
5. 不把未sealed异常吞成成功，也不增加外层定时retry；错误语义仍由现有cursor/source-growth边界负责。

## 后果

`SourceEpoch`继续表示下载内容世代；Reader-local encoded source handle成为DecodeSession cursor生命周期的第二个必要binding identity。projection rebuild不再让decode继续消费已被替换的source handle。
