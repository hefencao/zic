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

Architecture 中的“当前实现事实”必须能由 production source、owner test 或平台桥源码支持。角色窗口、水位、并发、缓存容量和生命周期等数值必须与代码常量同步。不得写：

- 单轮错误报告；
- Trace 统计；
- 运行环境缺少工具链；
- “已通过测试”；
- 版本标题；
- 暂时性 workaround。

### SPEC

描述产品和工程合同，即“必须满足什么”。Spec 不声明当前已经满足。任何新需求可以先进入 Plan；只有确定为长期合同后才进入 Spec。

### IMPLEMENTATION_PLAN

只列未完成工作、优先级、进入条件和退出条件。完成项必须删除，简短结论进入 CHANGELOG 和当前状态。禁止保存逐版本“已实施计划”。

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

Handoff 每轮覆盖更新，不累积历史。当前有效状态只指向 `docs/IMPLEMENTATION_STATE.json`。

### IMPLEMENTATION_STATE.json

保留全部 requirement ID、当前合同、有效状态和独立剩余验收；部分验收必须明确 remaining_acceptance。pending 未单列 remaining_acceptance 时，整个 current_contract 仍待验。缺少历史原始文件不代表产品缺陷，不授权重改已验生产行为。

最新验证和设备安装信息覆盖更新；原需求措辞、逐轮过程、重复子审计和原始文件清单留在归档，不复制到当前状态。该文件保持在 96 KiB / 400 行以内。

### docs/archive/adr

已归档 ADR 保存重要技术决策、背景、取舍和后果，暂不新增。它们是历史资料；只在追溯具体决定时读取，并核对当前源码和稳定文档。状态行必须只使用下列一个值；部分取代关系写在正文，不得拼接进状态值：

- Proposed；
- Provisional；
- Accepted；
- Superseded；
- Rejected。

“代码已写入”不自动等于 Accepted。需要设备/工具链事实才能成立的决策，在完成验证前使用 Provisional。

### CHANGELOG

保存版本历史和用户可见/工程变更，不承担架构说明。

### docs/archive/audits

已归档记录保存历史：

- 问题清单；
- 所有权清单；
- 被否决方案；
- Trace/错误报告分析；
- 单轮验证命令和结果；
- 未验证项。

暂不新增或持续扩写 audit；当前待验事项更新已有 Plan/状态，简短变更写入 CHANGELOG。未经验证的推断在当前状态中明确标注，不得直接升级为 Architecture 事实。

## 2. 证据等级

- **Source-inspected**：源码和引用已核对。
- **Static-verified**：静态门禁或编译 stub 通过。
- **Toolchain-verified**：真实 analyzer/test/build 通过。
- **Device-observed**：设备 Trace 或人工复现。
- **Device-verified**：同条件修复后复验通过。

文档中的事实必须使用匹配的等级。设备 Trace 的单次统计不能改写跨设备性能规格。

## 3. 更新规则

每轮按实际变更更新已有文件：

- CHANGELOG；
- IMPLEMENTATION_STATUS；
- NEXT_CHAT_HANDOFF；
- IMPLEMENTATION_STATE.json；
- 未完成事项变化时更新 IMPLEMENTATION_PLAN。

发生稳定所有权、默认策略、生命周期、缓存边界或长期合同变化时，必须在同一轮更新 Architecture/Spec；发现它们已与 production source 不一致时也必须立即校正。README 通常不随版本更新。

修改前先检查目标段落的父标题、production owner 和同主题现有段落，再按组件职责编辑；详情布局归详情章节，Home 组合与生命周期只描述 Home 的职责。不能凭邻近关键词选择插入位置。

## 4. 删除和迁移

发现历史段落放错位置时：

- 版本变更保留在 CHANGELOG；
- 既有决策与验证记录迁入 docs/archive，引用同步迁移；
- 当前结论与剩余验收进入 IMPLEMENTATION_STATE.json；
- 其余重复内容直接删除，不创建新的“大杂烩历史文档”。

测试与 trace 文件按必要性保留：保留原始报障输入、开放问题所需的最小复现文件和当前复验结果；验收完成后保留简短结论，删除不再服务开放问题的原始采集文件。重复 trace、过期截图/XML/APK、旧备份及临时工作树及时删除。`.log`、临时 trace 目录和私有缓存执行同一规则。优先复用现有构建产物，当前截图/XML/结果按用途覆盖。临时目录无论成功或失败均在退出时清理。搬到仓库外不等于清理，不新增逐轮清理清单。

## 5. 门禁

`tool/check_documentation.py` 应拒绝：

- README、Architecture、Spec、Plan、Status 中的逐版本标题；
- README 中的 release notes；
- 超出合理长度的稳定文档；
- Plan 中的大量完成历史；
- Status 中多个历史版本章节；
- 缺失当前验证等级或文档职责说明。
- 当前状态丢失 ID、隐藏剩余验收、计数失配或重新积累历史对象；
- 详情布局误归 Home，以及恢复已退役的当前文档目录。
