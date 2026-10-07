# ADR 0368: Android library backup uses existing OS document operation

Status: Accepted

## Context

The ordinary Release's Settings→Data→Export backup fails before opening a
document picker: `UnimplementedError: getSavePath() has not been implemented.`
The official file_selector feature matrix marks save-location dialogs unsupported
on Android. The app already owns a working ACTION_CREATE_DOCUMENT operation for
Trace exports. The shared Data settings failure field also mislabels this backup
failure as a cache inspection error.

Official documentation was fetched through Context7 from `/flutter/packages`:
https://github.com/flutter/packages/blob/main/packages/file_selector/file_selector/README.md

## Decision

Keep buildImportedLibraryBackup and its store-owned snapshot/durability barrier.
On Android send the JSON payload and application/json MIME through an App-local
document-export channel. MainActivity binds this alias to the existing OS
document operation and single pending result/payload lifecycle. No second picker
owner, worker, network path, file-selector dependency or Trace log state is added.
Trace methods, Downloads destination, JSONL name handling and cancellation/host
lifecycle keep their existing contract. Other platform branches are unchanged.

The platform returns the selected document URI or null on cancellation. Errors
propagate once, without retrying the unsupported picker. Backup errors use the
existing copyable diagnostic snackbar and do not overwrite cache inspection
state. Settings busy lifecycle still covers the operation.

## Validation and limits

A controlled unsupported-picker regression fails with the same API error before
the Android branch. Three tests cover one store snapshot, JSON bytes/name/MIME,
success, cancellation and one failure without fallback/retry. The first widget
fixture incorrectly left a debug-platform override until teardown and an earlier
unsupported-channel fixture stalled; these are excluded test evidence. The
correct fixture uses ordinary async tests and restores platform/messenger state.
Required gate2181/Rust22 and all three ABI/JNI checks pass. Ordinary minified
Release saves a29,986,222-byte JSON backup, genuinely cancels without creating a
file, then saves again with all sections equal except createdAt. Data export
returns enabled and cache statistics remain unaffected. The first Back within a
DocumentsUI child directory only navigated to Downloads; foreground guard
rejected dependent app input. This script navigation is excluded product
evidence. The scope-inclusive ordinary Release saves another29,986,222-byte
backup with all sections/86 entries, then successfully exports6753 complete
Trace events. The count-inclusive required gate passes2184 tests across27
suites plus Rust22; all three ABI/JNI checks pass. Its ordinary minified
Release also exports6616 events from t0 without truncation or task failure.
The existing single pending platform operation therefore remains usable by
backup and Trace. Independent Reader input/cadence and final display acceptance
stay open; this export change does not relax chapter-model identity.
