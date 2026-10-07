# ADR 0378: Source browse canonical projection and navigation preserve source coordinates

**状态：Accepted**

## 背景

SWG-PLAN-032 的受控普通来源页返回两个 raw locator，来源确认它们具有同一 canonical
identity。旧投影逐条构建稳定 key，产生两个同 key 的卡片；封面 Future 缓存仍只发一次请求。
两个有效 failing-first 分别覆盖原始条目数步长和显式 native nextOffset。聚合搜索已有
first-occurrence canonical 归并，普通投影缺失该步骤。
隔离真机进一步暴露上一页固定减24，把来源实际步长25回退到1而非0。
来源往返专项还确认：已恢复的页码被后续默认 browseOffset0 的加载覆盖。

## 决策

在现有普通 browse 查询边界归并来源确认的 canonical identity，保留源顺序中的首条 summary。
cached 与 refreshed page 在投影比较前使用同一归并。无重复时继续使用原 page object；
归并不在逐帧 builder 执行，不增加持久 map、缓存、owner 或来源类型分支。
点击与资源请求继续消费该 summary 的当前 raw locator/cover URI。
显式 nextOffset 仍由来源决定；有后页且无显式坐标时，从归并前的 raw item count 推导步长。
不得从显示卡片数推导下一请求，也不改 native page、source/cache/transport 数据 authority。
Trace 保留原 itemCount，并分别记录 projectedItemCount。聚合搜索与 artwork Future 语义保留。
既有来源页保存已接纳的访问坐标，上一页回到实际前一坐标，序号按访问路径展示。
路径只承载 UI 导航意图，随现有 query/filter/section/page0 边界重置；同页刷新不增加访问。
来源 view snapshot 复制不可变路径，切回来源按恢复的页码加载，缓存恢复也使用 canonical 投影。
重新发现的 section/filter 改变请求分区时回到0并重置路径，不跨分区沿用旧导航。
Reader、NetLane、workers、7/3、2/1、预算与 native ingress 锁不变。

## 验证与后果

专项覆盖一张 canonical 卡片、单次封面请求、首条 raw 命令、fallback/native 坐标和缓存刷新
的 changed=false/State 身份。缓存夹具关闭时须泵已有 fake event loop，再 join close；
首次专项因此挂起已作为夹具缺陷排除，没有修改生产 lifecycle。
专项53项及原3项quarantine通过，覆盖来源往返与缓存恢复。
隔离设备首轮17项通过、上一页坐标失败已保留；最终18项全部通过，请求25→0→24。
当前2206项/27组、Rust22与原3项quarantine门禁通过；三ABI Profile/普通Release、JNI/FFI及AGP stripped一致性通过。
普通Release一键导出8069事件、taskFailed0，真实native20页请求0→24→切源恢复24→0，恢复changed=false。
五次静置slider首帧约16–135ms、四次正确首尾跨章与五条Mihon主列表版本/ABI通过。
本轮slider媒体已缓存，不据此主张cold/origin延迟；ADR0377的真实page78 origin证据继续保留。
最大21.299ms build在第21章返回第20章末页之后，15.949ms reconcile仍无匹配CPU归因；旧长帧/GC仍开放。
此前门禁/Profile属于上一页/来源恢复修复前快照，已单独归档，不代表最终验证。
该受控输入不能证明某个已安装来源真实返回过重复项；独立长帧、GC、最终显示和全来源仍开放。
证据见 `docs/archive/audits/source-browse-canonical-page-projection-2026-10-02.json`。
