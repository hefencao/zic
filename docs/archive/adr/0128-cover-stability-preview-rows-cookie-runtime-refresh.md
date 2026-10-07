# ADR 0128：封面稳定恢复、预览专用行与插件验证会话

**状态：Accepted**

## 问题

dev.142 设备日志显示同一 Venera 封面在没有成功 source/frame 的情况下被重复请求十余至三十余次；Mihon 验证成功后又出现 Cloudflare verification failed，Venera 同时出现短路 `StateError`。预览等面积行仍把宽度转成巨大间隔，详情和漫画源刷新手势也不一致。

## 决策

1. loader closure identity 不参与 artwork reload。source 自动重试只保留一次；ImageStream 重建期间保持稳定占位图，成功帧到达后才替换。
2. 预览按实际行执行“含横图最多 2 张、纯竖图最多 3 张”；只在相邻三个候选内允许一次最小局部重排，使第三个横图与第一个竖图配成两张行，并把中间竖图留到下一行。用户设置可进一步降低上限。每行按完整可用宽度反算等面积尺寸，移除内层 Card 和水平 padding。
3. 详情和漫画源统一使用 `AppPullToRefresh`：顶部边缘触发、位移 72、可见进度、保留旧内容。
4. browser snapshot 返回 `updatedAt` revision；每个 runtime process/site/UA 最多导入一次同 revision，避免旧 `cf_clearance` 覆盖后续 response cookie。
5. MethodChannel runtime 对明确 retryable 的生命周期错误 envelope 原地重新激活并重试一次，包括 `runtime-closing`；业务错误和来源验证错误不自动重试。详情页只保存稳定 source ID，实际预览、评论、章节确保、缓存失效和验证回调每次解析当前 active source，插件重启后不继续调用已关闭 adapter。

## 所有权

- encoded artwork/cache：既有 ResourceCache/资源网关。
- artwork presentation recovery：App artwork widget。
- preview row policy：详情 presentation。
- browser snapshot/Cookie handoff：network_bridge Android boundary。
- runtime process recovery：plugin_host_bridge。
