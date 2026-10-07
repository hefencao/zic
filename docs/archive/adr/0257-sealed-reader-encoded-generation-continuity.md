# ADR 0257：sealed Reader encoded generation 与 transient physical session recreation 解耦

状态：Accepted（dev.279）

## 背景

09:37 dev.278 真机 Trace 中，本地 page5 第一次进入约304ms首帧；短期retention后二次/三次进入约366ms/357ms。每次Reader re-entry都为同一批本地 exact DownloadId重新创建 DownloadSession object，并连续触发约11个`physical-generation-changed`。current与已保留邻页的热DecodeSession被机械失效，current还同时退休UploadSession；随后本地文件重新读取、decode/upload重建。

dev.277把“same DownloadId但不同DownloadSession object”统一视为新的Reader encoded generation，用于修复mutable/incomplete projection跨physical generation复用。该规则对未完成source是必要的，但对Reader已经拥有`sealed + sourceReady + failure==null`的完整immutable encoded source过宽：transient physical owner object recreation并没有证明encoded bytes改变。

## 决策

`DownloadIngressProjectionRegistry`继续拥有physical session到Reader-local encoded source的generation边界，但必须区分两类情况：

1. existing projection仍incomplete/failed，或仍有pending synchronized attachment：same DownloadId的新DownloadSession继续按dev.277严格创建fresh projection/source。
2. existing projection已`sealed + sourceReady + failure==null`，且没有pending synchronized attachment：其immutable encoded generation可跨same exact DownloadId的transient DownloadSession recreation保留。registry从旧physical fan-out detach，并把entry的concrete session owner更新到新session；不得重新attach sealed projection到新physical live fan-out。
3. `LiveCoordinator`以projection object identity判断Reader encoded generation。projection相同而physical session object变化时只更新source-watch session pointer并记录`sealed-source-generation-preserved`；不得invalidate decode/upload。projection变化才继续执行既有`upload -> decode` physical-generation invalidation。
4. 旧same-id DownloadSession的late teardown不得按logical id删除已经转移给新session的entry；`detach(session)`必须校验concrete session identity。

该例外只适用于already-sealed Reader-local immutable source，不允许unfinished prefix、failure或late replay跨physical generation继承。ADR0232的logical→不同physical DownloadId rebind路径不受影响。

## 保持不变

- dev.277 synchronized replay closure、Artifact promotion read path与generation dispose barrier继续冻结。
- dev.278 UploadRegistry concrete DecodeSession binding继续冻结。
- previous3/next7、body5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1、Venera并发、cache容量均不改。
