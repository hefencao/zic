# dev.165 验证结果

## 范围

本轮验证针对两条结构性收口：

1. artwork response cache 不再向 presentation 暴露可被 LRU/trim/invalidate 删除的内部文件路径；
2. Home“更新”只投影“已加入书架 + source-confirmed update signal”，阅读进度与普通 metadata 更新不构成更新。

## 已执行并通过

- `python3 tool/check_dart_structure.py`
  - `Dart structure: OK (341 files, 129 test files)`
- dev.75–dev.97、dev.99–dev.165 历史 Python gates：通过。
  - dev.98 未执行，原因见“基线限制”。
  - 其中 dev.79 的旧 gate 原先绑定已被取代的 encoded-file 专用实现，本轮迁移为 generic owned-byte contract；没有恢复旧 API。
- `python3 tool/test_vertical_geometry_cover_trace_contract.py`
- `python3 tool/test_source_resource_binding.py`
- `python3 tool/test_ui_architecture_contract.py`
- `python3 tool/test_venera_bootstrap.py`
- `python3 tool/test_venera_reader_preflight.py`
- `python3 tool/test_dev164_home_projection_artwork_runtime_generation.py`
- `python3 tool/test_dev165_artwork_lifetime_home_update_semantics.py`
- `python3 -m py_compile tool/*.py`
- 对全部 `tool/*.sh` 执行 `bash -n`
- production/tests 全仓确认不存在：
  - `PersistedResourceFile`
  - `ResourceCacheByteStoreFileAccess`
  - `ResourceCacheFileByteStore`
  - `locate()` cache-file presentation path

## `check_repo.py`

`python3 tool/check_repo.py` 仍只在唯一基线 dev.164 已继承的 pinned archive 缺失处停止：

`third_party/source_archives/libwebp-1.6.0.zip`

本轮没有从旧项目、旧 ZIP 或其他临时目录补入该文件，也没有把这一项描述为通过。

## 当前环境未执行

当前执行环境没有 Flutter/Dart SDK，因此没有实际执行或宣称通过：

- `flutter analyze`
- Flutter widget/unit tests
- APK build
- 真机验证

新增的 `library_ui_test.dart` Home 更新语义测试已写入源码，但需要用户本地 Flutter 环境执行。

## 设备闭环重点

下一份设备 trace 应重点确认：

1. 已成功 `SourceReady -> FirstFrame` 的 durable artwork 在 Reader 返回、cache trim、内存压力后不再出现因 backing cache file 消失导致的 `homeCoverDecodeFailed`；
2. Home 更新区只出现“已加入书架且其已知章节目录后来发生变化”或“已发现新的同源版本”的漫画；
3. 仅阅读、仅浏览、阅读进度更新、普通 title/cover metadata 变化都不会产生 Home 更新条目；
4. 在加入书架之前已经发现的旧 update signal 在首次加入书架时清除，不把过去事件伪装成入架后的新更新。
