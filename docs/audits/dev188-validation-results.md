# dev.188 验证结果

## 已执行并通过

- `git diff --check`。
- `python3 -m compileall -q tool`。
- dev.157–dev.188 release/ownership gates；dev.175历史gate仅把 `CancelToken implements TaskControl` 的旧字面要求更新为新的 `PriorityObservableTaskControl` 子接口，原 TaskControl / priority / cancellation 所有权检查未放宽。
- `tool/check_documentation.py`；`NEXT_CHAT_HANDOFF.md`保持80行。
- Dart structure：343 files / 129 test files。
- Dart library directive order。
- Pipeline runtime compile boundary、test quarantine。
- Venera network policy、response headers、Reader preflight、Node bootstrap、native binary。
- source-resource atomic binding、Reader streaming、Pipeline demand stability、UI architecture。
- Android runtime dependency、trace export、texture bridge Kotlin compile、frame trace、vertical geometry/cache trace。
- Mihon entry/payload/ABI/classloader/read-only/chapter contracts、external login/settings、Cloudflare classifier。
- native header contract。

## 行为回归源码

新增但因当前环境无 Dart/Flutter SDK而未执行：

- queued Venera waiter从780升到1000时必须立刻重新评估active plan preemption；preemption request不能提前释放single permit。
- active Venera plan从820降到700时，已等待的previous=780必须重新形成pressure；仍保持 `maxActive == 1`。
- NetLane active same-key priority migration必须从scheduler-owned token发出priority change，不重启transfer。

## 完整检查限制

`bash tool/check.sh`仍在第一项因基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip`退出；本轮没有从旧基线注入该archive。因此dev.98/libwebp source-build smoke及其后的full-check串联不宣称通过。

当前环境检测到 Node，但没有 Dart/Flutter；所以 analyzer、Dart/Flutter package tests与Android App build未执行，不宣称通过。

## 结论

静态/ownership层面 dev.188 ready for device verification。真机优先验证同一download在等待Venera gate期间发生780→900→1000时，新的current pressure是否即时下沉；若该动态rank缺口消失但request-plan仍为秒级，再增加gate-wait / `onImageLoad` / bridge-network分段观测，而不是增加JS并发或整章预解析。

## Exact patch replay

最终候选patch从dev.187基线生成后，在重新解压的原始dev.187完整包上执行 `git apply --check --index` 与 `git apply --index` 均通过；replay树与dev.188工作树排除`.git`/构建缓存后1196个文件逐文件SHA-256一致，且应用前后均不存在`.zic-workspace.json`。
