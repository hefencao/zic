# dev.231 required exact durable target 审计

## 00:19 dev.230 真机证据

- `verified-transfer-acquire-alias` 43次。
- `taskFailed/sessionBusy/writerBusy`均为0。
- `restored-equivalent`继续命中，普通artifact handoff出现`skip-verified-equivalent-durable`。

## 根因

`CompositionDownloadTransferRuntime.persistPromoted(B)`在B alias到physical A时仍先`handoff.persist(A)`，promotion observer也默认以A为durable target；随后再materialize B，导致required B把physical anchor A额外持久化。

## dev.231

- required exact targets由physical owner claims提供给promotion handoff。
- auto promotion直接写required exact target，不先写physical anchor。
- explicit barrier只确保请求exact ID durable。
- chapter verified-equivalent behavior test新增A durable必须为空、B durable存在及`stored-required-exact-alias`诊断断言。
