# ADR 0374: Source roster updates preserve active browse generation

**状态：Accepted**

## 背景

普通 Release 的来源页 Trace 连续记录五次相同 `browse-start`，只有最新 UI generation 的
completion 被接纳。UI 将无关 source-id 列表变化当作当前来源变化，清空 section 后从第一页
强制刷新；`refreshBrowsePage` 会绕过缓存的 pending join，真实 source loader 因而重复调用。
同一轮 projection publication 还为未变化的 external source 新建缓存 decorator，使对象身份
变化再次触发 UI reload。两者都不是 NetLane 或传输 worker 的职责。

## 决策

普通 browse 只因当前来源选择、活动 source binding 替换或显式查询/刷新而重新加载。
无关来源增删/重排只更新可选列表并失效旧聚合结果；聚合搜索仍在列表变化时退出并走既有
普通 browse 路径，保持 request-generation retirement。真实切源保留原目标 projection 处理。

`HomeSourceProjection` 仅从自己的当前来源集合复用 decorator：底层 source、响应 cache
和 producer transport generation 都必须相同。decorator 创建时保存不可变 binding generation，
只用于 composition identity 比较；实时 `resourceTransportGenerationIdentity` 仍直接委托 producer。
设置/登录在同一 adapter 中推进 generation、活动 adapter 替换和 cache handoff 都创建新绑定。
不新增 source state、retry、network eligibility、长期 map 或 scheduler；Reader/Pipeline 无改动。

## 验证与后果

生产修改前，pending browse fixture 在加入两个无关源后真实 loader 从一次变三次；
普通已加载分页丢失第二页，projection reuse fixture 也证实未变 source 被重新包装。
聚合退出原行为单独通过。四项 focused checks 与当前 2200 项完整门禁通过；普通 native Release
完整 9767 事件仅有五次明确输入对应的 browse，管理往返未追加请求，热门第二页的内容与页码
保持。pending loader 的精确合流由 widget 行为测试证明；真机只证明单次初始 browse 与已加载页保留。
证据、测试夹具错误与未验范围见
`docs/archive/audits/source-roster-browse-generation-regression-2026-10-02.json`。
