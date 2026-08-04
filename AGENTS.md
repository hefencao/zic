# Project Rules

- Do not run `dart format`. Make only minimal, manually formatted edits.

- Release delivery must include a complete ZIP, SHA-256 and a baseline-to-release patch generated for `git apply --index`.
- Resolve `patch_dir` from `ZIC_PATCH_DIR` or the local `.zic-workspace.json`; do not hard-code a machine-specific directory.
- `.zic-workspace.json` is machine-local and must not be included in release ZIPs or generated patches.

- Patch application instructions must use `"$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"` directly; do not introduce a chat-only `PATCH_DIR` variable.
