# ADR 0317：来源条漫置信与 VibeVenera adaptive type 投影

## 状态
Accepted。取代 ADR 0316 第 4–7 条的单向来源 weight；ADR 0316 的 model v6 几何规则继续有效。

## 问题
ADR 0316 的来源先验使用 0–1 单向 weight：0 表示没有来源证据，1 表示强条漫，无法表达“该来源几乎全部是页漫”。

复核 VibeVenera 后还发现，ZIC 的 `AdaptiveReaderMetadata.sourceType` 和 classifier 已支持 `paged/vertical/animated` 高置信 source hint，却没有生产数据源：Venera 原生 `comic.adaptiveType` 没有跨 plugin runtime boundary，远程来源名称和官网也没有投影给 classifier。

## 决策
1. 来源用户先验改为条漫置信 `sourceWebtoonConfidence`，0=强页漫、0.5=中性/自动、1=强条漫；它仍是证据，不是漫画级手动方向 override。
2. `AppPreferencesController.sourceAdaptiveWebtoonConfidences` 是唯一持久 authority。0.5 不落盘；Reader 不监听、不回写。
3. classifier 使用有符号 bias `2 * confidence - 1`，并对称加入 `vertical += bias * 1.5`、`paged -= bias * 1.5`。
4. 旧 `sourceAdaptiveWebtoonWeights=w` 仅在读取边界迁移为 `confidence = 0.5 + 0.5*w`。新评分 `(1.5w,-1.5w)` 与旧 `(3w,0)` 只差公共常数，因此 softmax、mixed score、方向与置信保持一致。新旧 key 同时存在时新 key 优先；后续写回只使用新 key。
5. 中性 0.5 保持原 metadata fingerprint；任何非中性来源置信进入 fingerprint。
6. catalog 增加 typed `SourceAdaptiveReaderType { paged, vertical, animated }`；未声明来源保持 null。
7. Venera activation 从 source-owned `comic.adaptiveType` 读取提示，规范化 paged/manga/japanese、vertical/webtoon/manhwa/korean、animated；未知值降为 null。Mihon 没有等价声明时不推断。
8. App composition 构建远程 Reader metadata 时投影当前 source descriptor 的 name、website 和 typed adaptive reader type；`ImportedImageChapterScreen` 只接受这份 immutable metadata，不新增持久 owner。
9. 漫画级显式方向继续最高优先。漫画自身明确 tag/动画证据高于来源先验；
   足够强的用户来源置信高于 provider 的 source-declared adaptive type 和来源 identity heuristic，
   使用户可以修正来源默认声明；不够强的来源置信继续作为 prior，不阻断 provider metadata。

## VibeVenera 对照边界
- 全局 adaptive toggle、漫画级 adaptive toggle/profile、0.60 apply / 0.80 stop、持久 profile：ZIC 已有。
- `comic.adaptiveType`、source name/url：此前生产链遗漏，本 ADR 接通。
- `mixed`：ZIC 继续用低置信/无 profile 表示。
- translation adaptation：ZIC 没有对应功能，不引入空壳设置。
- adaptive long-press zoom：ZIC 已有独立、显式的 paged/vertical zoom 用户设置，不让 classifier 静默改写用户偏好。
- animated preload adaptation：ZIC 由 Pipeline policy 与实测媒体能力 owner 管理，不让 classifier 建第二套预载策略。

## 后果
来源设置现在同时能表达页漫源和条漫源，旧单向权重无损迁移。Venera source author 的显式 adaptive hint 与来源 identity 进入现有 classifier，而 plugin runtime、App preferences、Reader 不新增并行判定 owner。
