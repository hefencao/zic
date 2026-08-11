# dev.212 根因审计：mapping 解码编译错误与重复后台重验证

## 输入

- `错误报告(20260811-022642).txt`
- `zic-debug-trace-2026-08-11T02-25-52.jsonl`
- 唯一代码基线：dev.211完整ZIP。

## 编译错误

`ComicVersionPageMapping.fromJson` 的 `json['verifiedAt']` 静态类型是 `Object?`。复合校验条件虽然检查了String类型，Dart并未把局部变量稳定提升为 `String`，后续 `DateTime.parse(verifiedAt)` 因此编译失败。修复采用显式类型分支与 `DateTime.tryParse`，而不是宽泛cast。

## Trace结论

- 冷启动后约3.48s已恢复3个persistent mappings、1113个equivalent pages，约3.61s创建Reader；说明dev.210 Reader fast path仍成立。
- 多个Reader `sourceRead`明确带 `verifiedEquivalentReuse=true`；dev.211 late-artifact equivalence真实生效，不需要继续扩大full-artifact alias。
- 同一约94秒样本产生15次 `version-page-mapping-warmed`，只有5个relation identity，单relation最多重复5次；多数 `registeredEquivalentPages=0`。重复来源是详情/Reader每次都安排warmup，而 `_versionReuseWarmups` 只去重并发、不保留已验证新鲜度。
- durable partial reuse与validatorless resume均有成功样本，因此本轮不扩大partial到hot session。

## 修复

- mapping verifiedAt严格解码；非法timestamp拒绝。
- 最近10分钟内所有mapping均有有效verifiedAt时跳过page mapping revalidation。
- `findComicVersions`仍每次入口异步执行；新relation、无verifiedAt或过期mapping继续强identity验证。
- 新增dev.212 gate与catalog JSON regression test。
