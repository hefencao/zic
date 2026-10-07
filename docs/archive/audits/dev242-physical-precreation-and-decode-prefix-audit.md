# dev.242 physical precreation / decode prefix root-cause audit

## Trace证据

- 07:51 Trace共3097条事件。
- 旧版本对应图片已有约4.85MiB physical partial；新版本current对应图片进入后建立新的exact physical owner并从0开始，而同一轮neighbor/prefetch对应页可正常`verified-transfer-acquire-alias`到旧owner。
- 后续verified acquire出现`candidateOwners=2`，说明同一verified-equivalence class已存在多个hot physical owner；此时NetLane只能把它们当独立task排序，表现为跨session rank异常。
- 唯一decode `taskFailed`：current WebP，sourceLength=786432，sourceSealed=false，failureClass=partial-source；同一图片后续在sourceLength=8,380,120时连续产出frame，说明首次失败具有增长前缀可恢复性。

## 所有权审计

| 事实 | 正确owner | dev.241漏口 | dev.242 |
| --- | --- | --- | --- |
| physical session创建 | transfer acquire/reconcile | `PipelinePageStream` presentation调用`registry.get(exact)` | presentation全改non-creating lookup |
| verified-equivalent partial | resolved physical session | current exact precreation阻断alias | reconcile先alias，PageStream后bind |
| progress | physical session snapshot | dev.236已正确，但被双owner输入污染 | 保持单projection，不复制progress |
| rank | NetLane / policy rank | 双physical task使同图被独立排序 | 先统一physical owner，不新增rank分支 |
| unsealed首帧decode | DecodeSession + source revision | native exception直接投影failed | 零成功frame时等待prefix增长 |
| sealed/post-frame decode | DecodeSession | 正常终局failure | 保持不变 |

## 结论

本轮的主要共同根因是“read path具有create authority”，不是partial算法、progress算法或rank公式本身。修复后必须先验证同一verified-equivalent图片只剩一个physical owner，再评价跨session调度。decode问题独立收口为source completeness语义，不与transfer rank耦合。
