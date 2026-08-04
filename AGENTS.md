# Project Rules

- Do not run `dart format`. Make only minimal, manually formatted edits.

- Release delivery must include a complete ZIP, SHA-256 and a baseline-to-release patch generated for `git apply --index`.
- Read `patch_dir` from `.zic-workspace.json`; do not hard-code a different patch directory in chat or tooling.
