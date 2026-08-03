# dev.98 验证结果

- 输入基线：`zic_v0.31.0-dev.97_midpoint-playback-trace-filter.zip`。
- 文件库源码：`libwebp-1.6.0.zip`，SHA-256 `9cdad01b79c62928a0da1353b5c8aaac427589944baebc4c61e3ac0e7289d7e6`。
- 干净 `src/dec/vp8_dec.c` SHA-256：`e35bbdd94e8f20ace4fa4f8c53e2fedf0acfaa7a5271e7a147e0fda1cd7f4416`。
- 输出版本：`0.31.0-dev.98`；App：`0.31.0+98`。

## 已执行

1. 全新 `ZIC_DEPS_DIR` 下运行 `bash tool/fetch_webp.sh`：从 retained archive 离线解压成功。
2. 连续两次运行 `bash tool/prepare_webp.sh`：返回同一单行 prepared path；无 `.rej`/`.orig`。
3. 人为修改 upstream cache 后再次 fetch：检测 hash drift，并从 retained archive 重建为干净 source。
4. 显式传入修改过的 source：在 patch 前以 clean source hash mismatch 拒绝，不再出现 `VP8Clear anchor found 0`。
5. `python3 tool/verify_libwebp_vp8_tls_patch.py <prepared>/src/dec/vp8_dec.c`：通过。
6. `ZIC_WEBP_HOST_LINK=static bash tool/build_webp_host.sh release`：CMake/Ninja 完整编译并安装 `libwebp.a`、`libwebpdemux.a`。
7. `ZIC_WEBP_HOST_LINK=static bash tool/check_webp.sh`：`libwebp incremental and loop fixtures: OK`。

## 仓库与合同验证

- `tool/check_repo.py`、Dart structure、directive order、Pipeline compile boundary：通过。
- dev.75–dev.98 所有历史/当前 ownership gate：通过。
- Android dependency/Trace、Mihon payload/ABI/classloader/read-only/chapter、Venera network/native/headers/preflight/bootstrap：通过。
- Reader layout/streaming、Pipeline demand、source binding、UI architecture、external login/settings：通过。
- native header：通过。
- 完整 `tool/check.sh` 因单次执行窗口在 Mihon/UI 阶段两次超时；按未执行位置分组续跑后，剩余项全部通过，没有测试失败输出。

## libwebp 构建

- static release：CMake/Ninja 编译与安装通过；incremental/loop fixtures 通过。
- shared release：CMake/Ninja 编译与安装通过；incremental/loop fixtures 通过。

## 完整包独立解压复验

- `unzip -t`：通过。
- 解压副本中的 `third_party/source_archives/libwebp-1.6.0.zip` SHA-256：通过锁定值校验。
- 解压副本在全新外部 `ZIC_DEPS_DIR` 下连续两次 `prepare_webp.sh`：返回同一单行 prepared path。
- 解压副本执行精确补丁语义 verifier：通过。
- 解压副本从 retained archive 完整执行 host static CMake/Ninja build：通过。
- 解压副本执行 incremental/loop Animated WebP smoke：通过。
- 解压前扫描完整包：未包含 `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、`target`、`__pycache__`、`.pyc`、`.class`、`.rej` 或 `.orig`。

## 当前环境未执行

- Flutter/Dart SDK 不可用：未执行 `flutter analyze`、Dart/Flutter tests、kernel snapshot。
- Cargo/rustc 不可用：未执行 `media_core` Rust build/test。
- Android NDK/Gradle/ADB 不可用：未执行 Android debug/release、ABI native build 与真机播放。
