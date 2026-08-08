# dev.167 验证结果

## 基线与范围

- 唯一代码基线：`zic_v0.31.0-dev.166_retained-artwork-cache-ownership.zip`。
- 设备证据：`zic-debug-trace-2026-08-08T09-45-09.jsonl`。
- 本轮范围：source browse artwork Presentation owner、canonical card State identity、source-card artwork trace、filter入口/section排序，以及相应文档/测试迁移。

## 已执行

- `python3 tool/check_dart_structure.py`：通过，341 Dart files / 129 test files。
- `python3 tool/check_documentation.py`：通过；`ARCHITECTURE.md` 418行，`NEXT_CHAT_HANDOFF.md` 79行，均在责任上限内。
- `python3 tool/test_dev137_*.py` 至 `tool/test_dev167_*.py`：全部通过，包括 dev.141/142 source section/filter历史合同迁移与 dev.167 owner gate。
- `python3 tool/test_dev75_*.py` 至 `tool/test_dev136_*.py`：除 dev.98外全部通过；dev.98依赖当前基线缺失的 `third_party/source_archives/libwebp-1.6.0.zip`，未从旧版本补入。
- `python3 tool/test_venera_bootstrap.py`、`tool/test_venera_reader_preflight.py`、`tool/test_source_resource_binding.py`、`tool/test_ui_architecture_contract.py`：通过。
- `python3 -m py_compile tool/*.py` 与全部 `tool/*.sh` 的 `bash -n`：通过。
- `python3 tool/check_repo.py`：仅在 dev.166基线本身缺少 pinned `libwebp-1.6.0.zip` 处停止。

## 工具链限制

当前环境没有 `flutter` 与 `dart` 可执行文件，因此没有实际执行 Flutter analyzer、`source_browser_test.dart` widget tests、APK build或真机验证；不得把 Python/static/Kotlin合同描述为完整 Flutter编译通过。本轮新增 widget合同已经写入源码，需用户本地工具链继续闭环。

## Patch replay

最终交付 Patch 从全新 dev.166基线建立 Git index后生成，并实际执行 `git apply --check --index` 与 `git apply --index`。回放后按发行排除规则逐文件比较 file set、SHA-256内容与 executable bit；最终冻结结果见本轮交付验证，要求 missing/extra/content/executable差异均为0。

## 设备验证重点

1. 同一漫画 `source list first-frame → details → back`，若 canonical identity与 cover URI未变，不应再次出现该 identity 的 `cover-load-start`。
2. browse pagination/SWR `changed=true` 只能改变 metadata projection，不能触发同页其它 cover重新加载。
3. 若 source-card仍失效，使用新增 `cover-source-failed` 与 `cover-decode-failed` 区分 source/cache层和 Flutter decode层，不再从 Home trace间接推断。
4. Mihon存在 filters时，分类栏应显示“最新 → 热门 → 筛选”；应用 filter后请求应携带唯一 `_selectedFilterIds` 状态，搜索展开层不再显示第二套 filter chips。
