# dev.166 验证结果

## 基线与版本

- 唯一代码基线：`zic_v0.31.0-dev.165_artwork-lifetime-home-update-semantics.zip`
- 输出版本：`0.31.0-dev.166`
- App build：`0.31.0+166`

## 本轮验证

- `python3 tool/check_documentation.py`：通过；同时将基线已超限的 `docs/ARCHITECTURE.md` 从 434 行收口到 418 行。
- `python3 tool/check_dart_structure.py`：通过，341 个 Dart 文件、129 个 test 文件。
- `python3 -m py_compile tool/*.py`：通过。
- `bash -n tool/*.sh`：通过。
- dev.75–dev.97、dev.99–dev.166 历史 Python ownership gates：通过；dev.98未执行，因为唯一基线缺少 pinned `third_party/source_archives/libwebp-1.6.0.zip`。
- `tool/test_source_resource_binding.py`、`tool/test_ui_architecture_contract.py`、`tool/test_venera_bootstrap.py`：通过。
- dev.152/dev.154等 Kotlin contract在历史 gate中实际调用 `kotlinc` 并通过。
- `tool/test_dev166_retained_artwork_cache_ownership.py`：通过，覆盖 maintenance compile closure、retained/transient persistence、metadata/artwork invalidation分离以及旧 file-path API继续禁止。

## 用户报告编译错误闭包

`错误报告(20260808-080601).txt` 中缺失的 `ResourceCacheByteStoreUsage`、`ResourceCacheByteStoreTrimReport`、`ResourceCacheByteStoreMaintenance` 已恢复为纯 maintenance contract；`FileResourceCacheByteStore`重新实现 inspect/trim。旧 `PersistedResourceFile`、`ResourceCacheByteStoreFileAccess`、`ResourceCacheFileByteStore`、`locate()`没有恢复。

当前执行环境没有 Dart/Flutter SDK，因此不能声称实际完成 `flutter analyze`、Dart/Flutter tests或 APK build。dev.166已补 resource_cache/storage/catalog 单元测试和静态 compile-closure gate，用户本地工具链仍需实际 analyzer/build确认。

## 基线缺件

`python3 tool/check_repo.py` 在唯一基线既有的 pinned `third_party/source_archives/libwebp-1.6.0.zip` 缺失处停止。没有从旧项目包补该 archive，因此不能声称完整 `tool/check.sh` 或 libwebp source-build gate通过。

## Patch 回放与发行树

最终 Patch 从全新 dev.165基线实际执行：

- `git apply --check --index`：通过。
- `git apply --index`：通过。
- 回放树与交付工作树逐文件比较：`1103` 个发行文件，missing 0、extra 0、内容差异 0、executable-bit差异 0。
- `.zic-workspace.json` 不进入 Patch/ZIP。
