# dev.98 libwebp 源码与补丁准备审计

## 问题清单

### 编译/构建错误

- dev.96 compact patch 并非基于文件库真实 v1.6.0 布局生成：前两个 hunk 可 fuzzy 应用，`VP8Clear` hunk 失败并生成 reject。
- dev.97 函数锚点 transformer 对本地已有差异源码报 `expected exactly one VP8Clear anchor ... found 0`，无法完成 prepared tree。
- `prepare_webp.sh` 的第一次执行曾把 `patching file ...` 输出混入命令替换结果，调用方无法把 stdout 可靠当作单一路径；现已将 patch 输出留在内部 log。

### 产品错误

- 无新的 Reader 产品逻辑变更。本轮不能以构建修复修改 50% 播放交接、纹理保活或 Pipeline demand。

### 性能问题

- 无新并发或缓存策略。保留归档只影响构建输入；运行时仍是双 Dart decode isolate、libwebp 帧内单线程与每 decode 线程单份 TLS workspace。

### 测试错误

- dev.97 只用缩小 fixture 验证 transformer，没有对用户提供的完整 `libwebp-1.6.0.zip` 执行 prepare/build。
- 旧门禁检查实现字符串而非归档 hash、upstream/prepared 分离、真实 patch dry-run 和完整编译。

## 所有权清单

| 状态/资源/命令 | 当前正确所有者 | 约束 |
|---|---|---|
| libwebp 版本、commit、archive/hash | `native/libwebp.lock` | 单一原子 pin，不由 build script 各自复制 |
| 官方 source archive | `third_party/source_archives/` | 只读输入，不原地展开或修改 |
| upstream source cache | `tool/fetch_webp.sh` | `.deps/src/upstream/`，漂移后从 archive 重建 |
| local VP8 TLS patch | `native/patches/` | 只描述 ZIC delta，必须匹配真实 v1.6.0 |
| prepared patched tree | `tool/prepare_webp.sh` | `.deps/src/prepared/`，先 dry-run 后 apply |
| patch 完整性 | `tool/verify_libwebp_vp8_tls_patch.py` | 独立语义 verifier，不靠任一 token grep |
| host/Android build/install | `build_webp_host.sh` / `build_webp_android.sh` | 只消费 prepared path，不修改 source |
| decode isolate、frame lane、播放状态 | `bridge` / `sessions` / `pipeline` | 本轮不变，构建工具不得反向拥有 |

## 被否决方案清单

- 不再忽略文件库源码而仅尝试网络 fetch。
- 不再使用 `apply_libwebp_vp8_tls_patch.py` 或同类函数文本锚点 transformer。
- 不再接受 fuzz hunk、`.rej` 后继续、或“发现任一 mempool token即成功”。
- 不再把 patched/手改 `.deps/src/libwebp-1.6.0` 当 upstream。
- 不再要求用户手工改脚本、删除 cache 或设置 unpinned flag 才能执行正常构建。
- 不把完整 libwebp 展开树、build/install 目录打入交付 ZIP；只保留锁定 source archive。
