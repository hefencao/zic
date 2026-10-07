# ADR 0232：logical source watch 绑定 physical generation

状态：Accepted

## 问题

dev.252后的01:44设备Trace中`taskFailed/sourceDisabled`均为0，但page81两次current均无first frame。该页new physical session已从artifact cache完整获得18,699,622 bytes并`sourceReady/promoted`，DecodeSession却持续`waitingSource`。Trace中唯一出现“同logical identity先verified-alias旧physical、旧owner退休后再启动新physical owner”的identity就是该页。

`LiveCoordinator`此前以`Map<DownloadId, SourceListener>`判断logical id是否已监听，但listener实际挂在当时的physical `DownloadIngressProjection`。demand gap并不会移除该listener；alias旧owner退休并清除alias后，同logical exact重新进入窗口会解析到新physical session，`_watchSource`却因logical key已存在直接返回。new physical sourceReady因此没有decode wake。

## 决策

1. source watch唯一状态改为logical DownloadId到`physical DownloadSession + DownloadIngressProjection + listener`的binding；只有session与projection identity均相同时才允许复用watch。
2. physical generation变化必须解绑旧projection listener，清空该logical source revision/wake-length与decode-consumed revision，并机械失效绑定旧ingress的DecodeSession；reconcile完成后统一从新projection重新wake当前decode demand。不得用timeout/retry代替换绑。
3. `DownloadIngressProjectionRegistry`对same DownloadId但不同DownloadSession对象视为新physical generation：旧physical fan-out、旧projection与SourcePool ingress必须机械退役，新session创建新Reader-local native source。
4. physical download/partial/provider仍由composition owner持有；source watch generation只属于Reader-local source/decode projection，不改变verified equivalence、3/7、frame credit、NetLane或durable identity。

## 后果

logical exact可跨verified alias、owner retirement和exact physical recreation继续使用同一个页面身份，但Reader-local source wake不会跨physical generation陈旧。DecodeSession仍只消费当前projection，不需要额外watchdog。
