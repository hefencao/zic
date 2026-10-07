# Promoted cache dirty-reopen authority audit — 2026-09-14

## 结论修订

最初设备证据把问题收窄到“ownerless READY sidecar 在 dirty reopen 时被 `CacheScanner` 删除”，这个定位解释了当时的直接触发链，但把“补齐 sidecar owner metadata”当成最终修复仍然不对。重新按 schema-8 数据模型审查后，根因是 **durable READY authority 已迁到 SQLite artifact/replica，但 recovery 仍保留旧 sidecar/session authority**。

schema-8 的正式边界是：

- `artifact_object`：immutable bytes/checksum identity；
- `artifact_replica`：sealed physical-copy locator authority；
- `cache_entry`：logical/exact binding，`path` 只是 compatibility mirror；
- `physical_media_artifact`：canonical physical routing；
- `physical_partial` / migration state：mutable 或迁移中的独立物理 authority；
- final `.meta`：可以保留 session/collision/诊断信息，但不是 sealed READY proof。

因此，缺失、ownerless、格式损坏或内容陈旧的 final sidecar都不能授权 recovery 删除一个 DB 已承认的 sealed replica，也不能反向把一个尚未 DB commit 的 final body升级为 durable READY。

## 历史触发证据

问题轮中 current page 367 的 canonical physical key 已解析成功，但本地 prepare 报 `ArtifactReadFailure(lengthChanged, .../final/-f27fefdf13a511b.bin)`，`committedLength` 回到 0；随后 current source-plan/host open进入网络，首帧约 7–8s。更早同一设备 trace 中一次启动出现多个不同 READY final 的 `lengthChanged`，排除了单文件偶发损坏。

另一历史轮形成了直接对应：startup `cacheScan` 报 `invalidMeta=3 / removedRecords=3`，随后恰有 3 个 canonical final 在 handoff preflight中结构失败并重新下载/持久化。旧 scanner 的确是删除正文的直接触发者；但这只能说明旧 recovery authority 错了，不能推出“sidecar必须成为更完整的READY权威”。

## 最终边界与实现

1. `CacheScanner` 改成 authority-aware orphan cleanup。DB replica/physical-partial/migration/live owner 命名的locator受到保护；sidecar本身不能创建、删除或修复 READY。
2. `cache_entry.path` 不再被 scanner 当 sealed body authority。compatibility path消失不能删除 logical READY。
3. READY 的真实正文缺失、unsafe locator、exact-length mismatch 等仍由普通 artifact→replica read path typed 检测并退休相应坏 replica；多 replica 时不连坐其他副本或 logical/canonical authority。
4. `StartupRecovery` 不再把 indexed READY 重新 materialize 成 `DownloadSession`；相应的 `DownloadRegistry.restoreIndexed()` 已删除。mutable partial仍在其独立 physical/index owner边界按需adopt/resume。
5. `PersistentDownloadArtifactStore._storePromotedArtifact()` 遇到同 exact、同 length/checksum 的READY时先通过 artifact/replica durable preflight，命中后直接返回；不会为复用 immutable body重新建立session，也不会顺手“修”final sidecar。只有真的需要新正文时才进入 mutable `DownloadSession` materialization。
6. 后续 schema-17 已闭合 final data rename→SQLite authority commit 的窄窗口：`artifact_promotion` 只记录已sealed partial的事务进度，按DB length/CRC验证source/destination后完成或回滚；它不恢复sidecar authority，也不把journal本身当READY。

## 机械回归

focused回归机械覆盖：sidecar-only final不能制造READY；DB-authoritative READY在sidecar缺owner字段时仍保留；`cache_entry.path`缺失不删除 logical authority；indexed partial没有sidecar仍可保留；missing partial只移除partial binding；未提交 final body按orphan清理；active orphan仍保护。另有真实 persistent-store 回归故意删除 READY `.meta` 中的 `download/downloadKey`，dirty reopen后仍可从 sealed replica读取；再次 `storePromotedArtifact()` 也不会重建session去修sidecar。

完整包级结果：Storage **163/163**、Sessions **332/332**、Downloads **397/397**。targeted analyzer无error/warning，仅保留已有info lint。

## 真机 dirty-reopen 闭环

本轮重新用包含最终authority重构的 profile Dart + release native 构建，并以 `adb install -r` 覆盖安装，未清用户数据；设备 `low_power=0`。在当前阅读历史进入 Reader、实际显示媒体后执行 `am force-stop`，确认 `.zic-cache-recovery-required` 存在，再 cold reopen并重新进入同一历史页。

重启前 App-private SQLite 已证明 current page 49 的 durable authority：

- physical key suffix：`single2:49`；
- artifact id：`-25c3b457d0bd9d92`；
- length：**16,588,616 bytes**；
- CRC32：**`b28982df`**；
- replica：`.../offline_chapters/final/-575a7edc1ba2c847.bin`；
- exact READY、artifact object、replica、canonical physical binding均指向同一proof。

fresh trace：`.log/zic-debug-trace-2026-09-14T02-09-39.jsonl`。dirty startup 的 `cacheScan` 为：

- `recovered=0`；
- `removedRecords=0`；
- `deletedOrphans=0`；
- `invalidMeta=0`；
- `sessions=0`。

这与旧行为的关键区别是：**READY没有被sidecar“恢复”一次，也没有被sidecar判死；startup没有重建READY session。**

重新进入 Reader 后，current page 49 同一个 `single2:49` 直接：

- `bound-ready-authority`, 16,588,616 bytes；
- `local-completion-short-circuit`；
- `state=promoted`；
- `networkAdmissionRequired=false`；
- local prepare约 9.654ms；
- mount→first-frame **167.199ms**；
- handoff `skip-cache-resident`，随后保持 canonical binding。

随后再次 force-stop并读取DB/正文，artifact object、artifact replica、physical binding、exact READY仍指向同一artifact，正文仍为16,588,616 bytes。

trace中确实有5个 `downloadStarted`，但它们属于邻页50/51/48/53/54等已有partial/miss的3/7预取任务，不是current page49。故本轮能证明的是“**该既有 READY current 没有因 dirty recovery回退网络**”，而不是整个Reader session完全没有网络流量。

## 后续边界

若未来再次出现“已缓存页重启后重新下载”，优先检查：SQLite artifact/replica 是否仍存在、对应 locator 的 typed structural read结果、`physical-local-prepare` action 与 `networkAdmissionRequired`。不要再以 sidecar owner字段、Reader私有缓存层、resolver retry或第二持久化owner掩盖问题。

promotion 的 `rename → DB commit` crash recoverability 已由下述 schema-17 transaction follow-up 实现。后续若再调整，只能沿同一DB progress→artifact/replica commit边界演进，不得回退到“扫描sidecar猜authority”或新增第二READY owner。

## Schema 17 follow-up: promotion transaction, not sidecar recovery

The authority rewrite intentionally exposed one remaining crash window: a sealed partial could be renamed to its final pathname before the SQLite object/replica transaction published READY. That does not justify making the final pathname or `.meta` authoritative. Schema 17 therefore adds `artifact_promotion` as progress-only metadata. It is created only from an indexed sealed partial with exact length/CRC proof, before the filesystem promotion, and names both source and destination candidates.

Open-time recovery enumerates only these rows. A matching destination is committed; a matching source with an absent destination is renamed, reverified, then committed; a conflicting destination is left untouched and the existing source partial remains authoritative. Final publication of artifact object/replica, exact READY, canonical physical binding, physical-partial retirement and journal deletion is one SQLite transaction. Dirty orphan cleanup protects both journal locators but cannot read the journal as READY authority. Final sidecars are not consulted.

The first implementation placed journal recovery before the process-owner marker check. Review caught that this let a second same-process `open()`—which must be rejected—mutate another live store's pending transaction before throwing. Recovery now runs only after the duplicate-owner guard (and after dirty orphan cleanup, which already protects the journal candidates). A regression seeds a live journal, attempts a second open and proves the journal, partial body and absent final remain unchanged.
