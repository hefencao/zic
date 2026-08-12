# ADR 0211：Required exact durable target without physical-anchor copy

- 状态：Accepted
- 日期：2026-08-12
- 版本：dev.231

## 背景

dev.225后consumer exact identity可在acquire时共享另一版本physical transfer；dev.230又删除artifact hard alias/rekey。但required chapter completion仍先`persist(session.id)`，再从physical exact durable复制到consumer exact ID，导致一个required command可能制造physical A + exact B两份durable body。

## 决策

1. `DownloadTransferOwner`公开当前physical transfer的required exact durable targets。
2. promotion handoff若存在required targets，直接从physical hot artifact、resident cache authority或resident replay materialize这些exact targets；不默认写physical anchor。
3. 无required target的ordinary promotion仍以physical session.id为默认durable target，并可因verified-equivalent durable body而跳过exact copy。
4. `persistPromoted(exactId)`仅验证acquire-time alias并确保该exact target durable，不再通过physical anchor durable中转。
5. 多个required exact consumer共享同一physical transfer时，各自exact target都可materialize；这是command completion语义，不视为错误重复。

## 后果

physical transfer identity不再隐式决定required offline storage target；exact durable副本只由真正required的consumer identity产生。
