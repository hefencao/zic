# ADR 0008: Android source networking and failure diagnostics

- Status: Accepted
- Version: `0.21.1-dev.25`

## Context

The repository does not retain Flutter-generated Android/iOS host projects. A fresh host is created
under `apps/app`, and the standard release manifest does not automatically grant application Internet
access. A release APK can therefore surface a Dart `SocketException` such as `Failed host lookup`
even when a browser on the same device can open the source website. Browser reachability also does
not prove that the application and browser use the same DNS, proxy or VPN path.

The previous source page rendered `Object.toString()` in a centered `Text`. Long request URLs and
causes could be clipped by layout and could not be selected or copied for diagnosis.

## Decision

Generated hosts are followed by an idempotent repository configuration step:

- `tool/configure_platforms.py` adds `android.permission.INTERNET` to the generated main manifest;
- `tool/bootstrap_platforms.sh`, `tool/build_android.sh` and `tool/run_android.sh` all invoke it;
- the configuration never weakens TLS, rewrites source hosts or bypasses upstream access controls.

Source failures are captured with their `Failure.cause` and stack trace. The primary source and
source-detail pages show a compact diagnosis plus a bounded scroll area containing selectable,
copyable full technical details. Secondary SnackBars expose a copy action.

`HttpTransport` adds a bounded connection timeout and OS errno text. `MangaDexSource` retries one
transient `ErrorCode.network` failure with a short delay. Persistent failures remain visible and
retryable; no unbounded retry loop is introduced.

## Consequences

- Fresh and existing generated Android hosts can be repaired without checking generated platform
  code into the repository.
- Release and debug builds share an explicit application networking requirement.
- Users can report an exact URI, errno, cause and stack rather than a truncated screenshot.
- Browser success remains only a diagnostic clue; application DNS/proxy/VPN behavior is not assumed
  to be identical.
- Native platform HTTP clients or a sandboxed source runtime remain future transport options; this
  decision does not replace the existing streaming DownloadSession transport.
