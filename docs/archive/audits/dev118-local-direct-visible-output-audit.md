# dev.118 本地直连与纵向可见输出审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.117_single-frame-webp-bootstrap.zip`
- 本地动态图 Trace：`zic-debug-trace-2026-08-04T06-07-40.jsonl`
- 纵向静态图 Trace：`zic-debug-trace-2026-08-04T06-08-33.jsonl`

## 问题分类

### 产品

- 本地文件读取被投影为下载进度，语义错误。
- 纵向只表达一个 target，其他仍可见页面没有权威 output demand。

### 性能

- local bucket=5 使多个大 SAF/content 文件同时顺序读取；并发时读取时长由约 0.12 秒扩大到 3–4 秒。
- staged local path 同时写临时 artifact，每个 1 MiB chunk 还承担约数十毫秒 artifact write。
- 静态 warm 以固定 target 尺寸估算槽位，没有使用页面实际尺寸。

### 编译/接口

- 新增 `PageRole.visible` 后必须覆盖所有 PageRole switch。
- `clamp()` 的 `num` 返回值需要显式转回 `int`。

### 测试

- 缺少全部可见页面 role/demand 测试。
- 缺少本地来源不显示下载进度、local cap=2 与 immutable disposition 合同。
- 缺少 FrameBudget 对 visible output 的所有权门禁。

## 所有权

- `local_media_ui` / `transport`：只读本地响应属性。
- `sessions`：DownloadSession ingress 和 FrameBudget。
- `pipeline_runtime`：来源 bucket、transfer projection、fallback bytes 读取。
- `reader` / `domain`：真实视口覆盖 observation。
- `pipeline`：visible role、静态预算和 demand。

## 已拒绝方案

- 只隐藏 loading/progress；
- 把 local bucket 也保留 5；
- 取消远端 5 槽或缩小 7/3；
- Widget 缓存 decoded image；
- 固定保留更多静态页面；
- 复用跨 Reader 可变 DownloadSession。

## 实现摘要

- 本地 `content/file/asset` 完整响应使用 immutable direct ingress；
- local bucket=2，remote/global=5；
- 本地 transfer progress 隐藏；
- presentation fallback 校验 validators/length 后直接重读不可变来源；
- ReaderObs 增加全部可见覆盖；
- Pipeline 增加 visible role；
- visible 静态页获得一帧 demand；
- FrameBudget 保护 visible output；
- 静态预算按页面尺寸逐项扣减。
