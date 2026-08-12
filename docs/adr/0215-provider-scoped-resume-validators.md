# ADR 0215：Provider-scoped resume validators

## 状态
接受，dev.235。

## 背景
跨版本verified equivalence允许新exact request在acquire前加入既有physical `DownloadSession`。dev.227已经明确：physical session只拥有hot artifact/writer/committed prefix，实际transport必须使用当前claim的provider exact URI。

此前`DownloadSession`却只保存一份无URI scope的`Validators`。当physical A的partial被provider exact B继续消费时，`DownloadJob`会把A产生的ETag/Last-Modified发送给B URI。server/CDN可以因此拒绝Range并返回200，迫使仍然正确的A/B等价partial进入full-body prefix catch-up。

## 决策
1. committed partial bytes继续属于physical `DownloadSession`，direct verified equivalent consumer可共享同一连续prefix与writer。
2. ETag/Last-Modified属于产生它们的actual provider request URI，而不是physical session identity。`DownloadSession`同时记录validator与`validatorRequestUri`。
3. 所有网络/replay continuation必须通过`resumeValidatorsFor(actualUri)`取得validator。URI scope不匹配等价于“当前provider没有strong validator”，不得发送foreign validator。
4. scope不匹配不得删除、复制或重建partial。若total length可信，继续使用既有最多64KiB validatorless overlap Range验证continuity；后续append仍从原committed boundary单调前进。
5. response成功绑定时由`DownloadJob`用实际`requestUri`更新validator scope；resident immutable ingress同理。
6. physical A cold-store时只允许持久化对A canonical URI有效的validator。若当前session validator属于B，cold A entry写空validator；字节与total length照常保存。
7. metadata升级为v3并持久化`validatorRequestUri`。历史v2 metadata没有可证明scope：恢复时保留partial和total length，但清空validator，下一次由overlap proof重建网络知识。
8. `residentCacheBacked`与`begin/append/sealDurableCachedIngress`只剩测试引用，删除；生产与测试统一使用`residentBodyBacked`和resident immutable ingress API。

## 不做
- 不改变NetLane priority、full-body cost admission或restart-cost retention。
- 不增加Reader/playback/network第二调度器。
- 不把validator scope当成跨版本equivalence proof；equivalence仍由现有强identity owner提供。
- 不因scope mismatch materialize第二份exact partial。

## 结果
partial byte reuse与provider request validation成为正交authority：physical owner可最大化复用已下载prefix，同时每个exact provider只使用自己产生的HTTP resume validator，避免由foreign `If-Range`制造冗余full-body下载。
