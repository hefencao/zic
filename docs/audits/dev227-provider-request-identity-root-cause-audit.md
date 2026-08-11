# dev.227 provider request identity root-cause audit

## 基线与证据

- 唯一源码基线：`zic_v0.31.0-dev.226_phase-e-takeover-contraction.zip`。
- 真机Trace：`zic-debug-trace-2026-08-11T15-29-22.jsonl`，6095条事件。

## Trace结论

- `verified-transfer-acquire-alias`：13次，全部`joined-existing-physical`。
- alias目标状态：5 promoted、1 receiving、1 idle、6 failed。
- `taskFailed`：43次，全部为`Failure(source): unsupported URI scheme: venera-resource`。
- 60个page host中33个dispose前`firstFrameReady=false`，最长约11.18秒。
- legacy `verified-equivalent-promotion-takeover`仍为0；因此本轮问题不是late takeover缺失。

## 源码根因

`DownloadTransferOwner._runDownload()`已经从preferred claim取得`sourceId=claim.exactId`，并以`provider.transportFor(sourceId.canonicalUri)`选择transport。但`DownloadJob._open/_openRange`仍调用`session.id.canonicalUri`。

跨版本alias后：

```
physical session = old A
provider claim    = new B
transport         = B consumer transport
open URI          = old A   <- 错误
```

Venera opaque runtime resource只在拥有它的Reader/source gateway中有效，因此B transport无法打开A的`venera-resource`，最终落入不支持该scheme的IoTransport。

## 修复边界

- physical session identity：artifact/writer/hot partial/resume continuity。
- provider exact identity：transport选择、source bucket、实际full/range/resume request URI。
- `DownloadJob.requestUri`显式承载后者；legacy exact调用可省略。
- 不通过禁止failed alias掩盖问题。failed partial只要仍有可信physical prefix，可由新verified provider通过现有resume proof恢复。
- 不继续删除late compatibility takeover，待dev.227真机确认Phase C1恢复后再进入下一轮Phase E。
