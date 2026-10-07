# dev.250 ByteResponse flow-control API 闭包审计

## 问题清单

- 编译错误：用户本地Flutter/Dart构建报告`ByteResponse.flowControl` getter不存在；`ByteResponse`自身constructor initializer也报`flowControl`不是instance field；rhttp adapter无法解析`ByteResponseFlowControl`。
- 产品错误：本轮未收到新的运行时产品证据；编译失败使dev.249无法进入设备验证。
- 性能问题：不在本轮修改范围；dev.249 frame-credit/backpressure参数全部冻结。
- 测试错误：dev.249静态gate只搜索enum/使用点字符串，没有验证公共类型constructor parameter、instance field和跨package facade export同时闭合，因此在无Dart SDK环境下产生假通过。

## 所有权清单

- `ByteResponseFlowControl` enum：唯一属于`transport`。
- `ByteResponse.flowControl` capability value：唯一属于每个transport response instance。
- direct HttpClient/rhttp response是否声明`streamBackpressure`：各transport adapter负责事实赋值。
- artifact/source wrapper：只能透传已有`response.flowControl`，不得重判能力。
- frame credit policy：Pipeline；active task credit与等待：sessions/NetLane/DownloadJob。
- `downloads_bridge`依赖边界：继续只依赖`downloads` facade；不新增对`transport`的第二直接依赖。

## 被否决方案

- 用`diagnostics['flowControl']`字符串代替typed field：把能力变成弱类型观测元数据，否决。
- 在downloads/sessions定义extension getter：制造第二能力事实并掩盖公共API不完整，否决。
- 删除`flowControl`使用让编译先过：会让dev.249在materialized fallback上执行假pause或彻底失去真实backpressure边界，否决。
- downloads_bridge直接新增transport依赖：当前downloads facade已经承担ByteResponse跨桥导出，新增第二依赖无收益，否决。

## 修复

只补齐`ByteResponse`字段和downloads facade enum导出，并加强API闭包gate。没有改变任何调度/预取/流控策略。
