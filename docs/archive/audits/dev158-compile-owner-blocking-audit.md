# dev.158 编译闭包、Artwork所有权与潜在阻塞审计

## 基线与输入

唯一代码基线：`zic_v0.31.0-dev.157_progress-chapter-artwork-owner-cleanup.zip`。本轮首先处理用户错误报告中的真实编译断点，再审查 artwork、Reader/storage、downloads/pipeline 的潜在阻塞和兼容残留。

## 编译根因

1. `storage_bridge` 新增 `readEncodedResourceBytes` 时遗漏 `dart:typed_data`，导致 `Uint8List` 无法解析。
2. dev.157 将详情封面 Presentation State改为稳定 identity，但本地详情 `_ComicDetailCover` 调用点漏传 `presentationIdentity`。
3. dev.157 已让 preview/avatar携带独立 artwork role，但详情 loader仍是 cover-only函数签名，因此 `resourceRole` 迁移只完成一半。
4. `_ComicDetailsDecodedArtwork` 已改为消费 `ImageProvider`，调用方仍把 `EncodedResourceSource` 以旧 `source:` 参数传入。

这些是同一次 owner-cleanup 的公共 API迁移不完整，不应通过兼容 overload/facade掩盖。

## 收口

- loader统一为 `ComicDetailsArtworkLoader`，cover/preview/avatar均显式传 `resourceRole`；composition仍由唯一 `ComicSourceResourceGateway`解释 role和cache identity。
- `storage_bridge` 作为平台/存储边界统一负责 `EncodedResourceSource -> ImageProvider` 和必要的 bytes materialization。
- 普通无裁剪 artwork直接复用 `StableArtworkImage`。只有 Venera crop/尺寸测量需要显式 ImageStream；其加载态不再同时构建第二个 `Image`，避免同provider双listener造成重复decode/layout。
- 全仓搜索确认不保留旧 `ComicDetailsCoverLoader` 或 `_ComicDetailsDecodedArtwork(source: ...)`兼容路径。

## 阻塞审查

- Reader checkpoint仍是 `SendPort`入队，storage-owned progress isolate/WAL按8秒 idle/30秒maximum batch提交；本轮未把 durable barrier放回Reader route。
- App/Reader/Pipeline/resource presentation未发现同步文件读取；downloads中一个同步文件读取已包在 `Isolate.run`。
- dev.157当前 artifact backend已经拥有 stream/invalidate能力，read scheduler nullability和 pipeline prewarmer均使用现有capability边界；旧报告中的对应错误不是当前基线问题，因此未恢复兼容 facade。
- 稳定文档中残留的 presentation retry/watchdog/raw-cover旧合同与ADR0142冲突，本轮删除，防止后续再次按过时规范重建竞争恢复链。
