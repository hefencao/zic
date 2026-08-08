# ADR 0154：Source Filter View、书架投影与下载完成反馈所有权

状态：Accepted

## 背景

dev.169 已按 Mihon `FilterList` ABI完整转译 schema/state，dev.170又收口了 WNACG媒体网络与 Reader retry owner。但新的设备 trace暴露出三个仍被状态复用掩盖的问题：

1. `filterState` 既被用作“用户 override”，又被用来推断“是否处于筛选模式”。因此空 override无法表达“使用插件默认 FilterList”；分类栏焦点仍停留在 Latest/Popular。
2. 漫画源页没有书架状态投影，source card无法表达同一 canonical comic已经属于 Home/library书架。
3. Home卡片下载勾由任意 `ChapterDownloadSnapshot.isComplete` 推导，把 durable cache residency误当成一次显式下载命令完成。

## 决策

### 1. Filter view 与 filter state分离

`SourceSearchFilterState` 只保存相对插件默认 `FilterList` 的用户 override；空 map表示“没有 override”，不表示普通 section browse。

Presentation持有独立 `filterViewActive`。点击“筛选”并直接应用必须进入 filter view；Latest/Popular chip失去焦点。filter view请求不继承先前 section，因此其 effective `sectionId` 为 `null`。

Catalog response cache identity增加独立 `useFilters` mode。相同 `section/query/offset/filterState={}` 在 section mode与filter mode必须是不同 key。

runtime payload同样携带 `useFilters`。Mihon driver在 `useFilters=true` 时即使 override为空，也必须重新取得 source `getFilterList()`，保持其默认 state并调用 search API；只有 `useFilters=false && query为空` 才走 Popular/Latest。

### 2. Source card不拥有书架状态

书架成员事实仍由 Home/library canonical `ComicPreference`拥有。DemoHome按 canonical alias合并 preference，只把 `inShelf`投影给 source card。

source card仅负责表现：已入书架时增加书签标记并降低封面亮度。它不得保存、修改或推断第二份 shelf membership。

### 3. 下载完成勾表示命令反馈，不表示离线事实

真实下载/cache/artifact状态继续属于 downloads owner。Home卡片的右上角完成勾改为短生命周期 Presentation feedback：

- 显式单章节下载命令返回且 snapshot complete：记录 `chapterComplete`，显示空心勾；
- 显式整本下载命令进入 `WholeComicQueuePhase.complete`：记录 `comicComplete`，显示绿色实心勾；
- 任意一个已有 chapter cache、Reader预取或历史离线 artifact都不能自行生成完成勾；
- feedback以 canonical comic identity关联，进入对应详情页时消费；App重启不恢复该瞬时反馈。

正在进行中的真实下载进度仍可读取 downloads snapshot/whole-comic queue展示，不受此决策影响。

## 后果

- 默认插件筛选第一次成为可无损表达的真实请求，而不是依赖“至少改过一个 filter值”。
- “热门页里应用最新排序筛选”不会再表现为热门 chip仍选中；filter view拥有焦点和精确 cache identity。
- 漫画源页书架视觉状态与 Home/library共享单一事实源。
- durable cache可长期存在，但不会制造误导性的“本次下载完成”UI；单章命令与整本命令结果可辨识。
