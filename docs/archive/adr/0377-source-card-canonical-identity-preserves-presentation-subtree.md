# ADR 0377: Source card canonical identity preserves its presentation subtree

**状态：Accepted**

## 背景

SWG-PLAN-032 的已有测试只统计封面请求次数。canonical Future 缓存让请求保持一次，
却不能证明封面 State 存活：Sliver 卡片有 canonical key，其内部 InkWell 仍使用 raw
comic locator 作 key。元数据刷新改变 raw alias 后，Sliver Element 保留，交互子树却重建。
有效 failing-first 直接观察到旧 Image State 已 defunct，而新 State 仍引用同一缓存 completer。
第一次测试误取无状态卡片的 State，已作为夹具缺陷排除；真实失败是 Image State 身份断言。

## 决策

内部交互 key 直接使用现有来源确认的 canonical comic identity，普通/聚合卡片共用现有
builder 与身份能力。`sourceComicCardKey` 的输入明确为 canonical identity；点击仍使用
当前 summary 的 raw comicId。封面 URI 与显式 reload token 的局部更新合同保留。
不增加 GlobalKey registry、跨查询缓存、presentation owner 或来源/请求身份镜像。
Reader、NetLane、Pipeline、workers、资源窗口与预算保持原合同。

## 验证与后果

已有回归补强 Sliver Element、Image State、单次封面请求与最新 raw locator 点击断言。
修复前只有 State 身份断言失败；修复后专项通过。dev167 的 raw interaction key 文本要求
会重新引入该缺陷，已更新为 canonical key 检查，其 filter/artwork/gateway 断言保留。
隔离设备夹具继续覆盖来源/解码失败、显式刷新与离屏完成，并追加 alias State 和命令检查；
不打开用户数据或真实来源。完整门禁2203/Rust22、三 ABI Profile/普通 Release、JNI/FFI与13项隔离设备检查通过。
普通 Release8162事件复验五次静置slider、四次首尾跨章及五条Mihon版本/ABI，taskFailed=0；
其中第78页确为committedLength0/priority1000/HTTP200下载，首帧在下一输入前完成。
该决策只修复 canonical alias 下的 presentation 重建，不能解释或关闭独立第21章入口34.772ms build、Reader GC、
无匹配 CPU 的返回帧、最终显示、全来源或原 112 项范围。
同页实际重复canonical alias仍需按catalog projection验收，不能由单个alias更新夹具代替。
证据见 `docs/archive/audits/source-card-canonical-subtree-regression-2026-10-02.json`。
