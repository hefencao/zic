# dev.169 验证结果

## 范围

本轮验证对象：Mihon source-owned FilterList schema/state 转译、source-browser筛选 UI、typed filter state请求/cache identity，以及 dev.168默认第一栏目所有权保持。

## 已执行

- `tool/check_dart_structure.py`：通过，341个 Dart文件、129个测试文件。
- `tool/test_dart_library_directive_order.py`：通过。
- dev.75–169历史 Python ownership gates：除 dev.98外均分段通过；dev.98仅因当前唯一基线缺少 pinned `third_party/source_archives/libwebp-1.6.0.zip`未执行。
- `tool/test_dev169_mihon_filter_schema_contract.py`：通过；其中实际使用 `kotlinc` 编译并执行纯 Kotlin `MihonFilterCodec` smoke，以自定义子类名验证 Group/Sort/Select/Text/CheckBox/TriState/Header/Separator识别和状态回写。
- Mihon entry/payload/ABI/classloader/read-only/chapter contracts：通过。
- source-resource atomic binding、UI architecture、Venera bootstrap、external source settings、Android runtime dependency closure：通过。
- Android texture bridge Kotlin compile：通过。
- `python3 -m py_compile tool/*.py`、`bash -n tool/*.sh`：通过，生成的 pycache/class文件已清理。
- documentation responsibility gate与 dev.139 current documentation gate：通过；`ARCHITECTURE.md`保持418行，未放宽420行职责上限。

## 基线缺件

`python3 tool/check_repo.py`在当前 dev.168唯一基线既有缺件处停止：

`third_party/source_archives/libwebp-1.6.0.zip`

本轮未从任何旧ZIP/旧工作树补入该文件。

## 当前环境限制

当前环境没有 Flutter/Dart SDK，因此没有实际执行 `flutter analyze`、Flutter widget/unit tests、APK build。新增的 Dart测试属于待用户本地工具链验证项；不得把静态 gate结果表述为这些工具已通过。

## Patch / ZIP 回放

预回放已从全新 dev.168建立Git基线并实际执行 `git apply --check --index` 与 `git apply --index`：1116个发行文件，missing=0、extra=0、content diff=0、executable-bit diff=0。最终 validation 文档冻结后重新生成正式 Patch并再次回放：同样为1116个发行文件，missing=0、extra=0、content diff=0、executable-bit diff=0。最终ZIP执行 `unzip -t`、独立解压与核心 gate复验。
