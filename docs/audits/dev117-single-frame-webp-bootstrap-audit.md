# dev.117 单帧 WebP Bootstrap 审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.116_runtime-webp-classification-compile-closure.zip`
- 横向动态 WebP：`zic-debug-trace-2026-08-04T05-10-49.jsonl`
- 纵向静态图：`zic-debug-trace-2026-08-04T05-14-50.jsonl`

## 证据

### 横向动态 WebP

- 章节 22 页，current page 16。
- 9 个页面 artifact 已完整进入 session 并 promoted。
- policy 输出 7 个 decode、7 个 upload，其中 7 个被当作 static-warm。
- 3.8 秒内没有 `decodeState`、`decodeRefill`、`frameDecoded` 或首帧。
- 原因不是 source 缺失，而是全部 target=1 demand 被 staged refill 跳过。

### 纵向静态图

- host 已为 `keepAlive=true`。
- 两页被权威分类为 frameCount=1。
- static-warm 扩展到 7 decode / 7 upload 后，只有两页产生 frame 0。
- 其余 target=1 邻页没有 refill，导致成为 current 前没有首帧。

## 所有权修改

- `sessions`：一帧 bootstrap 与早期 animation metadata 上报。
- `local_media_ui`：本地 WebP 初始作为潜在动画候选。
- `pipeline` 的静态预算、动画 staged 水位、7/3 下载窗口不变。

## 保持不变

- 下载全局 5 槽和来源 bucket；
- 动画 c/n/m/p 8/6/4/3；
- 静态 96 MiB 选择预算、128 MiB output budget；
- last keep；
- cache direct ingress 与空 artifact 自愈。

## 未验证

当前环境无 Flutter/Android/ADB，设备效果仍未验证。
