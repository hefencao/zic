# dev.98 后续交接

唯一后续基线：`zic_v0.31.0-dev.98_libwebp-archive-exact-patch.zip`。不得再以 dev.97 或更早 ZIP、旧 prepared tree、函数锚点 applier 或记忆源码覆盖。

- 三清单审计：`docs/audits/dev98-libwebp-source-patch-audit.md`
- 验证明细：`docs/audits/dev98-validation-results.md`
- 架构决策：`docs/adr/0082-pinned-libwebp-archive-and-exact-patch.md`
- dev.97 Reader/Trace 验证：`docs/audits/dev97-validation-results.md`

## 已完成

1. 文件库 `libwebp-1.6.0.zip` 已保留到 `third_party/source_archives/`，archive 与干净 `vp8_dec.c` SHA-256 均锁定。
2. `fetch_webp.sh` 默认离线解压到 immutable upstream cache；缓存漂移会从归档重建，显式 source 必须匹配干净源哈希。
3. VP8 TLS patch 已按真实 v1.6.0 源码重新生成；`prepare_webp.sh` 先执行 `--dry-run --fuzz=0`，再应用并由 verifier 检查完整语义。
4. 已删除 `apply_libwebp_vp8_tls_patch.py`；不得恢复 token grep 接受 partial patch、fuzzy hunk 或 `VP8Clear` 字符串锚点。
5. host libwebp 1.6.0 static CMake/Ninja build 和 incremental/loop Animated WebP smoke 已通过。
6. dev.97 的 50% 播放交接、Trace 合并与 identity 摘要保持不变；7/3、2/1、current/transition、5/3/2、双常驻 decode isolate、libwebp 帧内单线程均未改变。

## 后续验证

1. 有 Flutter/Android 工具链时依序运行 analyzer、受影响 package tests、App tests、Android debug/release 与真机 Animated WebP 往返切页。
2. Android NDK 构建必须使用仓库归档默认路径完成，不设置 `ZIC_WEBP_ALLOW_UNPINNED=1`。
3. 升级 libwebp 时必须同时更新 archive SHA、干净关键源文件 SHA、真实 patch 和 smoke；不得仅改版本字符串。
