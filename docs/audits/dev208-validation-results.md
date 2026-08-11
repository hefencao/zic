# dev.208 验证结果

## 基线与范围

- 唯一代码基线：`zic_v0.31.0-dev.207_version-artifact-alias-vertical-anchor.zip`。
- 本轮只修改版本关系投影、版本更新 presentation、artifact alias 复用方向及相应测试/文档；未修改 Venera/Mihon transport、Reader/Pipeline调度、水位或dev.207纵向anchor实现。

## 根因证据

用户新 trace 中 dev.207 曾成功准备一次版本artifact alias：`relationCount=1`、`candidateChapters=1`、`reusedPages=40`，证明旧缓存→新版路径本身可工作；之后另一个371页 Reader session没有第二次 alias preparation。源码同时显示dev.207只查询当前版本的 predecessor，故反向“新版缓存→旧版”没有候选。

旧版`!`方面，持久relation可存在但source browser同步`hasUpdate`只读取Home投影中的`sourceUpdateAt`；relation未进入Home projection，因此详情页未再次触发副作用时提示缺失。

## 已执行检查

通过：

- `python3 -m py_compile tool/*.py`
- `bash -n tool/check.sh`
- Dart structure：347 files / 130 test files
- Dart library directive order
- documentation responsibilities
- dev.139 current-code documentation consistency
- dev.122 vertical-ratio contract
- dev.135 unified version/cache identity
- dev.147 version UI
- dev.165 Home update semantics（已迁移掉superseded reconcile实现绑定）
- dev.171 shelf projection
- dev.173 migration/version/update badge
- dev.181 artifact-cache controlled origin
- dev.205 historical partial/cursor contract
- dev.206 Download-owned partial + Venera rhttp resolver boundary（含Kotlin compile）
- dev.207 version reuse / vertical anchor owner（已迁移掉superseded reconcile实现绑定）
- dev.208 version relation projection / bidirectional reuse
- source-resource atomic binding
- UI architecture
- Reader streaming/output
- Pipeline demand stability
- Venera bootstrap / Reader preflight / network policy / response headers / network cache
- external login bridge / source settings
- Mihon entry / Payload Context Kotlin compile / ABI / split classloader / chapter / read-only APK staging
- Android runtime dependency
- Android texture bridge Kotlin compile

`check_repo.py` 仍仅因基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` 停止；未从文件库或旧版本补入该归档。

当前环境：`kotlinc` 可用；没有 `dart` / `flutter`，因此没有执行也没有宣称 `flutter analyze`、Flutter/Dart tests 或 APK build通过。

## 候选 Patch 回放

清除工作目录的无关 executable-bit 污染后，从全新dev.207基线生成候选Patch：

- 实际内容修改/新增：26 files；
- work发行文件：1275；
- replay发行文件：1275；
- missing=0；
- extra=0；
- content diff=0；
- executable-bit diff=0；
- `git apply --check --index`：PASS；
- `git apply --index`：PASS。

## 包含 validation 后的正式候选回放

本报告纳入发行树后再次从全新dev.207生成Patch并回放：

- 实际内容修改/新增：27 files；
- work发行文件：1276；
- replay发行文件：1276；
- missing=0；
- extra=0；
- content diff=0；
- executable-bit diff=0；
- `git apply --check --index`：PASS；
- `git apply --index`：PASS。

## 最终冻结发行结论

最终冻结Patch按相同27-file变更集生成，并要求最后一次全新dev.207回放保持：1276个发行文件、missing=0、extra=0、content diff=0、executable-bit diff=0，且两条`git apply`检查均PASS。若任一条件不成立，该候选不得作为dev.208交付。
