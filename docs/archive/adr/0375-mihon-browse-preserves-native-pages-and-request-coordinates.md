# ADR 0375: Mihon browse preserves native pages and request coordinates

**状态：Accepted**

## 背景

普通 Release 来源页第二页返回空列表但仍有下一页。实际插件每页返回 20 项，UI 用返回项数
推进 offset 到 20；Mihon runtime 按请求 limit 24 换算页码，再对第一页 drop 20，因而返回空页。
插件每页超过 24 项时，旧 take(limit) 还会丢失原生页尾部。来源页大小不是 host 可推断的合同。

## 决策

`SourceBrowsePage.nextOffset` 为来源可选的只读下一次请求坐标；存在时必须严格前进，且
仅在 hasMore=true 时合法。Runtime adapter 验证并透传该坐标。Presentation 使用它推进请求，
未声明的 global-offset 来源继续按 offset + items.length 前进；精确缓存比较也包含该坐标。
空原生页仍有下一页时保留 pager，不用空项数推断终止。

Mihon runtime 要求 offset 按本次 limit 对齐，映射到一基 native page，保留 Popular/Latest/
Search/Filter 的原调用路径，返回完整 mangas 和来源 hasNextPage；下一坐标为 offset + limit。
不截断原生页、不根据项数推算页大小，不增加请求、缓存 owner、分页状态或调度通道。
Venera/global-offset 路径、取消退出、Reader、NetLane 与 worker 资源边界不变。

## 验证与后果

修改前 Kotlin 真实 browse 方法、UI 下一页和 runtime adapter 的独立回归均产生行为失败。
修复后 Kotlin 合同覆盖 20/30/7 变长页、四种入口、前返、空页及取消；adapter 43 项通过。
当前 2200 项完整门禁、Rust 22 项和三 ABI native Release 通过；同一真机来源热门第二页
以 offset24 返回 20 项新内容，管理往返保留第二页，上一页正确返回。完整 9767 事件无 taskFailed，
五次静置 slider 及六次首尾跨章符合原合同。35.255ms cached chapter return build 仍需独立归因，
不因分页验收关闭性能或全来源父问题。证据和测试夹具错误单独记录在
`docs/archive/audits/mihon-native-browse-pagination-regression-2026-10-02.json`。
