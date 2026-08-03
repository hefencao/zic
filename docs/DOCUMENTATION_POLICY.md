# Documentation Policy

本文件定义项目文档职责，防止单轮交付说明污染稳定架构和规格。

## 1. 文档职责

### README

只包含：

- 项目简介；
- 文档导航；
- 仓库结构；
- 初始化、运行、测试和构建命令。

禁止：

- 版本逐轮说明；
- Trace 数字和性能结论；
- “本轮修复”；
- 当前验证结果；
- 大段产品实现历史。

### PROJECT_CHARTER

只包含长期目标、非目标、原则和成功标准。不得描述某个 dev 版本的当前实现。

### ARCHITECTURE

只包含：

- 当前稳定所有权；
- 依赖方向；
- 数据流；
- identity；
- 生命周期；
- 并发与平台边界。

Architecture 中的“当前实现事实”必须能由源码和引用审查支持。不得写：

- 单轮错误报告；
- Trace 统计；
- 运行环境缺少工具链；
- “已通过测试”；
- 版本标题；
- 暂时性 workaround。

### SPEC

描述产品和工程合同，即“必须满足什么”。Spec 不声明当前已经满足。任何新需求可以先进入 Plan；只有确定为长期合同后才进入 Spec。

### IMPLEMENTATION_PLAN

只列未完成工作、优先级、进入条件和退出条件。完成项必须删除，并转入 CHANGELOG/audit。禁止保存逐版本“已实施计划”。

### IMPLEMENTATION_STATUS

只描述当前源码快照：

- 当前所有权；
- Implemented / Verified / Unverified；
- 当前开放问题；
- 当前 quarantine；
- 当前验证矩阵。

禁止追加历史版本章节。

### NEXT_CHAT_HANDOFF

只包含：

- 唯一继续基线；
- 必读顺序；
- 当前开放问题；
- 下一步命令；
- 不可改变的稳定边界。

Handoff 每轮覆盖更新，不累积历史。

### ADR

ADR 记录一个重要技术决策、背景、取舍和后果。状态必须是：

- Proposed；
- Provisional；
- Accepted；
- Superseded；
- Rejected。

“代码已写入”不自动等于 Accepted。需要设备/工具链事实才能成立的决策，在完成验证前使用 Provisional。

### CHANGELOG

保存版本历史和用户可见/工程变更，不承担架构说明。

### docs/audits

保存：

- 问题清单；
- 所有权清单；
- 被否决方案；
- Trace/错误报告分析；
- 单轮验证命令和结果；
- 未验证项。

未经验证的推断只能在 audit 中明确标注，不得直接升级为 Architecture 事实。

## 2. 证据等级

- **Source-inspected**：源码和引用已核对。
- **Static-verified**：静态门禁或编译 stub 通过。
- **Toolchain-verified**：真实 analyzer/test/build 通过。
- **Device-observed**：设备 Trace 或人工复现。
- **Device-verified**：同条件修复后复验通过。

文档中的事实必须使用匹配的等级。设备 Trace 的单次统计不能改写跨设备性能规格。

## 3. 更新规则

每轮默认只更新：

- CHANGELOG；
- IMPLEMENTATION_STATUS；
- NEXT_CHAT_HANDOFF；
- 本轮 audit。

只有发生稳定所有权或长期合同变化时，才更新 Architecture/Spec。README 通常不随版本更新。

## 4. 删除和迁移

发现历史段落放错位置时：

- 版本变更保留在 CHANGELOG；
- 决策保留在 ADR；
- 验证证据保留在 audit；
- 其余重复内容直接删除，不创建新的“大杂烩历史文档”。

## 5. 门禁

`tool/check_documentation.py` 应拒绝：

- README、Architecture、Spec、Plan、Status 中的逐版本标题；
- README 中的 release notes；
- 超出合理长度的稳定文档；
- Plan 中的大量完成历史；
- Status 中多个历史版本章节；
- 缺失当前验证等级或文档职责说明。
