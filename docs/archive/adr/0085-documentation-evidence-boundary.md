# ADR 0085：稳定文档职责与证据边界

- 状态：Accepted
- 日期：2026-08-03
- 适用范围：README、Architecture、Spec、Plan、Status、Handoff、ADR、CHANGELOG 和 audits
- 修正：ADR 0084 中版本绑定的 quarantine marker 改为稳定 `Q-xxx` ID

## 背景

稳定文档长期追加逐轮 dev 注记后，README、Architecture、Spec、Plan 和 Status 同时包含版本历史、错误报告、Trace 推断、验证结果、待办和交接。未经 Flutter/Android/设备复验的推断也被写成当前架构事实，使后续实现无法区分长期合同、源码事实和单轮候选结论。

## 决策

1. README 只负责项目入口、文档导航、仓库结构和命令。
2. Architecture 只负责稳定所有权、依赖方向、数据流、identity 和生命周期；不得记录 Trace 数字、测试结果、版本标题或环境限制。
3. Spec 只定义产品与工程合同，不声明当前实现已经通过。
4. Implementation Plan 只列未完成工作、优先级和退出条件；完成历史进入 CHANGELOG/audit。
5. Implementation Status 只描述当前快照和验证等级，不累积历史版本。
6. Handoff 每轮覆盖更新，只保存唯一基线、当前开放问题和下一步。
7. ADR 记录决策和取舍；需要工具链或设备事实才能成立的决策在验证前使用 Provisional。
8. 单轮问题清单、所有权清单、被否决方案、Trace 推断和验证命令只进入 `docs/archive/audits/`。
9. quarantine 使用稳定 `Q-xxx` ID，不把 release 版本写入测试控制标记。
10. `tool/check_documentation.py` 对稳定文档的职责、长度和版本历史泄漏做门禁。

## 被否决方案

- 把原有 5000 多行内容整体搬入一个新的 history 文档：只会移动混乱，不恢复职责。
- 在 Architecture 顶部继续追加“最新 dev 覆盖旧描述”：读者仍需解析所有历史冲突。
- 用 README 作为交付说明：会让项目入口随每轮增长。
- 把“源码已实现”写成“已验证”：静态检查不能替代 Flutter、Android 或设备验证。
- quarantine marker 绑定 dev 版本：每次版本升级都会迫使无关测试和历史门禁修改。

## 后果

- 版本历史仍可从 CHANGELOG、ADR 和 audits 追溯。
- 稳定文档显著缩短，阅读顺序和事实等级明确。
- 后续每轮默认只更新 CHANGELOG、Status、Handoff 和 audit。
- Architecture/Spec 只有在稳定所有权或长期合同发生变化时修改。
