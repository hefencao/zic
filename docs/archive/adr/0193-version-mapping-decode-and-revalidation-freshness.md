# ADR 0193：版本 mapping 解码与重验证 freshness

状态：Accepted
版本：0.31.0-dev.212

## 问题

dev.210引入 `ComicVersionPageMapping.verifiedAt` 并在dev.211将持久mapping用于 verified-equivalence，但 JSON factory 把 `Map<String,Object?>` 中的 `verifiedAt` 保持为 `Object?`，随后直接传给 `DateTime.parse`。用户本地Flutter/Dart编译因此报 `Object can't be assigned to String`。

02:25真机trace同时表明dev.211 equivalence本身已经工作：Reader前恢复3个persistent mappings并登记1113个等价页，后续读取出现 `verifiedEquivalentReuse=true`。但约94秒内同一批relation重复产生15次 `version-page-mapping-warmed`；多数记录 `registeredEquivalentPages=0`，说明详情/Reader入口重复执行版本page mapping重验证而没有新证据。

## 决策

1. `ComicVersionPageMapping.fromJson` 对 `verifiedAt` 先做 `Object? -> String?` 明确收窄，再以 `DateTime.tryParse` 严格解析并转UTC。非String与不可解析时间均抛 `FormatException`。
2. `verifiedAt` 同时承担mapping验证新鲜度事实；所有mapping都有时间戳且距离当前时间不超过10分钟时，该relation跳过昂贵 `loadComic + strong page identity` 重验证。
3. freshness只跳过page mapping重验证，不跳过 `ComicVersionSource.findComicVersions`。因此每次详情/Reader入口仍可异步发现新successor；新relation因没有mapping仍会立即验证。
4. mapping缺少 `verifiedAt`、时间戳未来异常或超过10分钟时必须重新验证。
5. verified-equivalence、exact-first lookup、durable partial复制与DownloadJob overlap验证语义不变。

## 结果

编译类型边界闭合；持久mapping从单纯审计字段变成有界重验证依据。版本发现保持及时，同时避免用户短时间往返详情/Reader导致同一强identity映射反复联网/解析。
