# dev.165 Artwork 生命周期与 Home 更新语义根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.164_home-projection-artwork-runtime-generation.zip`
- 设备 trace：`zic-debug-trace-2026-08-08T07-28-36.jsonl`

## Trace 证据

- 初始 source readiness问题仍可单独观察：trace 32/33/38/42 的 `homeCoverSourceFailed` 都是 `sourceAvailable=false`；这是既有显式 source dependency，不等于本轮间歇 decode 根因。
- trace 66 有一条 `sourceAvailable=true` 的真实 `Failure`（wn09），应继续沿 source/request/transport调查，不允许 presentation通用 retry掩盖。
- 更关键的是多张封面已成功后再失败：
  - local cover：trace 41 `durableCacheFile` → 47 `FirstFrame` → 590 `DecodeFailed`；
  - 18comic 186442：35 → 44 → 591；
  - 18comic 195520：36 → 45 → 592；
  - 另一持久封面：34 → 43 → 593。
- trace 601/602/603 与 608/609/610 甚至显示重新请求时仍能得到同样 `durableCacheFile` bytes，随后马上 decode失败，说明不能把问题归结为 live source不可用。

## 代码根因：cache-managed file 被借给长期 ImageProvider

- `FileResourceCacheByteStore.write()` 后会执行容量 trim；TTL/invalidate/clear也可以删除同一 `.bin`。
- dev.164 `ResourceCacheManager` 可以通过 file-access facade得到该 `.bin` 路径并返回 `FileEncodedResourceSource`。
- `StableArtworkImage` 把它转换成 `FileImage` 并长期持有。Flutter之后因 ImageCache/memory pressure重新 resolve/decode时，cache owner可能早已删除文件。
- 因而“首帧成功”与“稍后 DecodeFailed”并不矛盾：二者属于两个不同生命周期 owner。

## 结构修复

- 删除 response-cache file locate/borrow API；持久命中读取 bytes后返回 `MemoryEncodedResourceSource`。
- `FileEncodedResourceSource` 固定为 `localFile`，只允许导入本地稳定路径。
- 不增加 timer、watchdog、resume retry或 ImageCache eviction。

## Home 更新根因

- dev.164 `_mergedPreferenceFor` 的 fallback `inShelf=true`，导致 Home primary 在 preference enrichment前把未知远程 SavedComic当成书架漫画。
- 更新区对所有 `inShelf` 漫画按 generic `metadataUpdatedAt`排序，本身没有“source发现更新”的事实模型。
- 阅读历史/仅浏览记录因此可能间接进入用户理解为“新章节/新版本”的区域。

## 更新语义修复

- 新增持久 `SavedComicRecord.sourceUpdateAt`。
- 只有已有章节目录基线发生目录变化或首次发现新同源 successor/version才推进；普通 metadata和 progress不推进。
- Home update筛选严格为 `inShelf && sourceUpdateAt != null`。
- 远程未知 preference fallback为未入书架；第一次加入书架清除加入前 signal。

## 未声称

- 当前环境没有 Flutter/Dart SDK，未执行 analyzer/widget tests/APK真机构建。
- dev.164基线仍缺 pinned `third_party/source_archives/libwebp-1.6.0.zip`，未从旧包补入。
