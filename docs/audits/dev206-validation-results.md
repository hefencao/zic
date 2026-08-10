# dev.206 验证记录

## 当前环境

当前环境无 Dart/Flutter SDK；`kotlinc` 与 Java 可用。因此不声称执行 `dart analyze`、Dart/Flutter tests 或 Android Flutter build。

## 已实际通过

- `git diff --check`、`bash -n tool/check.sh`、`python3 -m compileall -q tool`；
- documentation responsibility、Dart structure（347 Dart / 130 test files）、directive order、Pipeline runtime compile-boundary；
- dev.175–192 ownership/preemption/rhttp/Venera连续门禁；dev.195/196 partial/Range、dev.197/198 trace、dev.199/200 admission/defer、dev.201–204 retention、dev.205 cursor supersession、dev.206 owner-boundary门禁；
- dev.206 Kotlin resolver facade使用最小 Android/MethodChannel stub 独立 `kotlinc` 编译通过；
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture；
- Venera network policy/cache/response headers/Reader preflight/native-binary/bootstrap；
- external login bridge；Mihon entry/payload/ABI/classloader/read-only/chapter；Cloudflare Kotlin；Android texture/trace/runtime dependency contracts。

Mihon chapter组合批跑曾达到单次工具窗口；随后单独执行通过，不把超时本身记为产品通过。

## 完整检查

`bash tool/check.sh` 已实际执行并返回1；它在第一项仓库检查因权威 dev.205 ZIP 继承缺失 `third_party/source_archives/libwebp-1.6.0.zip` 退出。没有从旧版本或文件库补入该 archive 来制造全绿。

## 关键边界

- `ArtifactCacheManager` 已不含 partial API，dev.205 错误报告中的三个 undefined-method 调用路径结构性消失。
- route retain/reentry 不做 durable partial checkpoint；true dispose/evict 才 drain，网络前可 cold restore。
- dev.205 cursor-reentry-before-stale-prefix-gate保留；`partialLoopMinFrames=30` 只存在于 DecodeSession production code。
- Venera production resolver不再包含 Kotlin `HttpURLConnection`、DoH或reflective OkHttp；requestId/driver close/host close均可落到 rhttp CancelToken。

## Patch replay / package

第一次 authoritative candidate replay 已从原始 dev.205 完整 ZIP fresh extract 初始化 baseline Git 后执行：

- `git apply --check --index`：通过；
- `git apply --index`：通过；
- 工作树与 replay：1268 / 1268 个有效文件；
- missing=0、extra=0、内容 SHA-256 / executable-bit diff=0；
- dev.206 新 PartialDownload owner、isolated Dart rhttp resolver、ADR0188、两份 audit 与 dev.206 gate 均实际包含在 patch。

写入 candidate 结果后已重新生成 patch，并完成 pre-final fresh replay 与 ZIP fresh-extract：两者均为1268 / 1268个有效文件，missing=0、extra=0、内容 SHA-256 / executable-bit diff=0；ZIP禁入项为0。

本审计文本第一版冻结后，已重新生成 patch 并完成 post-audit fresh dev.205 replay 与 ZIP fresh-extract：两者均为1268 / 1268个有效文件，missing=0、extra=0、内容 SHA-256 / executable-bit diff=0，ZIP禁入项为0。

写入该事实后将再次生成最终 patch，并执行最后一次 locked replay/package；最终交付只有在结果仍与上述数字一致时成立。
