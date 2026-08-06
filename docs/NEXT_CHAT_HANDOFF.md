# dev.139 后续交接

唯一后续基线：`zic_v0.31.0-dev.139_current-code-documentation-realignment.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0117-reader-resource-session-retention-and-affinity-removal.md`
8. `docs/adr/0118-unified-version-stable-cache-identities-and-verified-artifact-reuse.md`
9. `docs/adr/0119-catalog-cache-weight-and-compatibility-cleanup.md`
10. `docs/adr/0121-vibevenera-independent-transition-first-frame.md`
11. `docs/adr/0122-current-reader-pipeline-authority-consolidation.md`
12. `docs/adr/0123-home-cold-start-primary-and-optional-runtime-deferral.md`
13. `docs/adr/0124-home-cover-independent-foreground-completion.md`
14. `docs/audits/dev139-current-code-documentation-audit.md`
15. `docs/audits/dev139-validation-results.md`
16. `docs/audits/home-cold-start-cover-loading-audit.md`

## 当前代码事实

- NetLane 是唯一网络调度权威；不存在 holder/playback 驱动的网络资格门控。
- encoded window 为前 7/后 3，深度 decode 角色为前 2/后 1，holder 最大水位为 7/5/3/2。
- transition depth=0 独立执行一帧 bootstrap；获得首帧后恢复 staged current/neighbor refill。
- holder-driven playback 缺帧时保留当前 output；没有 startup-buffer。
- Reader 退出后最多保留 1 个 idle chapter resource session、TTL 2 分钟；used texture 不保留。
- Android 使用默认 platform channel、单 blit lane和 fresh used texture lifecycle。
- response cache 与 page artifact cache 是两个权威平面；App/Reader没有私有正文 LRU。
- Home 先发布 cover-bearing primary 并让出首帧；native media prewarm、整本队列 restore
  和外部插件 activation 在后台完成，source ready 后增量替换 projection。
- 首页封面冷 miss 使用独立的 foreground completion：encoded bytes 到达即显示 memory
  source，durable response write 后台排队；warm durable file hit 仍走文件源。
- 首页 artwork 先探测 raw stable cache，命中不解析 source/plugin；raw miss 才进入 source
  loader。dev.135 为 app 更新保留的 URL-derived/canonical 旧 key 兼容读取与 alias 回填已
  删除。来源确认过的 canonical comic identity 持久化在 SavedComic 元数据中，冷启动可在
  插件未激活时先归并同源 raw ID。IndexedStack 页面按当前导航 lazy 构建，未访问书架不会
  创建隐藏封面。
- 详情页顶部不重复显示标题；有进度时提供“继续”药丸按钮，阅读历史与按钮同一行并位于章节总数行上方，带时钟
  图标。详情页提供同源版本入口和迁移入口；Venera 版本通过来源适配器复用运行时网络/Cookie
  按 `#gnd` 关系读取，避免标题 browse 的浏览器权限错误。迁移面板显示当前插件/来源，允许
  同源不同 raw comic ID 的 E-Hentai URL 版本替换，并持久化已确认关系以显示旧版；目标写入并完成章节校验后清理旧版本记录。
- App-owned modal panel 的关闭统一为左下角 X，正向操作保留在右侧；详情迁移对话框和
  catalog 同源 ID 单测已通过。
- Venera 登录协议已接受 Android platform channel 解码后的嵌套 Map；`ComicManifest` 已
  携带可选首批 preview/comments 和 `Comic.sourceSubId`。`ComicPreviewSource`、
  `ComicCommentSource` 由 runtime/cache adapter 透传，详情页按能力显示预览栏、评论栏，
  评论支持分页次级页和按不透明回复 ID 的回复页；预览/头像复用现有 artwork loader。
- Home 更新区只取书架漫画并按元数据更新时间排序，阅读历史独立按进度更新时间排序；Reader
  在页码/模式变化和退出/生命周期暂停时 flush 进度，`HomeLibrarySession` 即时更新投影。
- 预览分页由 `loadThumbnails` 独立提供首批和游标，完整预览 URI 保留为绘制身份，artwork role/cache key 使用去 `@x/y` 的 base URI，使同一原图的不同裁剪共享编码字节；点击预览项直接复用 Reader 路由。
  预览默认单行，点击展开后自动消费分页并以 `PageView` 左右分页呈现固定行；纵向图每行三槽位，横向图占两槽位，图片区域封顶屏幕高度 80%；缩略图使用 `BoxFit.contain`，混合横纵向图片时保持比例并允许留白。
  Venera 预览 URI 的 `@x/y` 标识保留在 widget/painter 身份中，但 `onThumbnailLoad` 接收去裁剪 URL；图片失败占位为按 identity 稳定生成的柔和纯色，不再显示破损图标。

## 下一步

- 优先完成 `IMPLEMENTATION_PLAN.md` 中的设备与完整工具链闭环。
- 新 Trace 重点观察 transition first frame、NetLane priority、source growth、holder depth、deadline/present 和 readerSession retain/reuse。
- 首页冷启动 Trace 重点观察 `homeServicesReady`、`home-library-primary`、插件 ready、
  `homeCoverRequested`、各封面的 `homeCoverSourceReady` 和 `homeCoverFirstFrame`；需检查
  raw durable cover hit/source miss 分流、命中时是否零插件资源请求、canonical alias 是否在
  插件未激活时只读归并，以及慢封面是否仍影响快速封面。
- 发现实现变化时先更新 Architecture/Spec/Status/Handoff，不允许核心文档继续描述已删除路径。

## 不可改变的稳定边界

- 不缩小 7/3、7/5/3/2 或 5/3/2 来掩盖问题；
- 不恢复 FlowGate、startup-buffer、跨 Reader used texture 或 CPU affinity；
- 不在 Reader/App 新增 transport、正文缓存、cursor、frame 或 session 所有权；
- 不把 native prewarm、queue restore、plugin activation 或 enrichment 重新加回首页首帧门控；
- 正式 ZIP 不含 `.zic-workspace.json`，Patch 命令直接使用：

```bash
git apply --index "$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"
```
