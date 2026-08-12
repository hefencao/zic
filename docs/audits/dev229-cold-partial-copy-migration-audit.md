# dev.229 cold partial copy 迁移审计

## 23:03 dev.228 真机证据

- 总事件：5837。
- `verified-transfer-acquire-alias`：9次（4 promoted / 4 receiving / 1 failed）。
- `taskFailed/sessionBusy/writerBusy`：0；`downloadStarted` 30次/24个identity，无亚秒重复start。
- 34个page host中6个dispose前无首帧；最长current未首帧样本约6.2秒，event chain显示source prefix增长缓慢/页面随后切走，没有decode failed或永久source-wake断链。
- `version-durable-partial-reused`：4次，证明版本warmup的cross-version partial copy仍在实际工作。

## 根因分类

该partial路径仍是dev.210时代“source partial A → copy target partial B → B session restore”的补偿。dev.216之后physical hot owner已提升到composition，dev.225之后live equivalence已在acquire前共享；继续由Home/version warmup复制cold partial会让版本迁移层承担durable byte ownership，并制造重复exact partial。

## dev.229迁移

- version mapping仍负责登记verified equivalence proof；
- 删除warmup/Reader入口partial copy；
- physical prepare exact miss后直接查询direct verified equivalent cold partial；
- exact优先，equivalent candidate取最长prefix；
- equivalent validators清空，resume acceptance继续交给DownloadJob overlap proof；
- trace改为`session-partial-handoff action=restored-equivalent`。

这一步不把durable I/O前移到Reader planning，也不把cold exact IDs强行canonicalize成一个global map。
