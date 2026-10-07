# dev.170 Validation Results

## 范围

基线：`zic_v0.31.0-dev.169_mihon-filter-schema-state.zip`。

本轮验证针对：WNACG cleartext media host capability、external runtime retryability传递、Reader download terminal failure所有权、source-card失败诊断，以及相关既有 Mihon/Venera/source-resource/Reader边界。

## Trace 证据

`zic-debug-trace-2026-08-08T11-55-06.jsonl` 共 8994 条记录。WNACG browse/details/chapter catalog均成功；source browser 30 次 cover load全部在 source阶段失败且没有 decode failure。Reader出现 2788次 `downloadStarted`、2684次 `taskFailed`，其中2654次为同一 `UnknownServiceException: CLEARTEXT communication to img5.wnimg1.ru not permitted by network security policy`。6个主要 DownloadId分别被启动约446–516次，确认同时存在 Android cleartext capability缺口与 terminal failure无界重提。

## 已执行

- `tool/test_dev75...test_dev170` 历史 dev gate：95个脚本中94个通过；唯一未执行成功的是 dev.98 pinned libwebp gate，因为当前唯一基线缺少 `third_party/source_archives/libwebp-1.6.0.zip`。
- `tool/test_dev170_mihon_cleartext_media_retry_owner.py`：通过；验证统一 Network Security Config、无 WNACG域名白名单、retryability跨层、UnknownServiceException non-retryable、LiveCoordinator terminal latch与 source-listener单一职责。
- Mihon payload Context Kotlin compile、split classloader、ABI routing、chapter contract：通过。
- source-resource atomic binding、Reader streaming、UI architecture、Android runtime dependency closure：通过。
- Venera network policy、Reader preflight、Node bootstrap：通过。
- Dart结构检查：341个 Dart文件、129个 test文件，通过。
- Dart library directive order、documentation responsibility、dev.139 current documentation：通过。
- Android Manifest与 `network_security_config.xml` XML解析：通过。
- `tool/check_native_header.sh`：通过。
- `python3 -m py_compile tool/*.py`、`bash -n tool/check.sh`：通过。

历史 dev.152 gate曾写死 `details: runtimeError.details` 源码文本；dev.170仍保留全部 runtime details，但改为 spread并附加 retry metadata，因此该 gate迁为验证 `...runtimeError.details` 与 `runtimeErrorCode`，没有恢复会丢 retryability的旧写法。

## 基线阻塞/未执行

- `tool/check_repo.py`：仅因基线缺少 `third_party/source_archives/libwebp-1.6.0.zip` 停止；没有从旧版本补入。
- dev.98 libwebp archive/prepare gate：同一基线缺件阻塞。
- 当前环境无 Flutter/Dart SDK，因此没有执行 `flutter analyze`、Dart/Flutter tests、Android Flutter build；新增的 `live_coordinator_test.dart` terminal-failure测试与 `runtime_source_adapter_test.dart` retryable-runtime测试需用户本地工具链执行。
- 当前环境无 Cargo；libwebp pinned archive又缺失，因此 native/source完整构建未执行。
- 真机 WNACG cover/page请求仍为 Unverified；静态配置不能替代 Android/OkHttp设备行为。

## Patch 回放

从全新 dev.169项目根目录建立 Git基线。产品/文档树冻结前的预 Patch实际通过 `git apply --check --index` 与 `git apply --index`，1120个发行文件逐文件一致。写入本 validation后重新生成冻结 Patch并再次回放：

- `git apply --check --index`：通过；
- `git apply --index`：通过；
- 1121个发行文件逐文件比较：missing 0、extra 0、content diff 0、executable-bit diff 0。

最终交付 Patch从同一冻结树重新生成并必须再次满足上述1121文件一致性；本文件写入后不再修改产品或验证结论。
