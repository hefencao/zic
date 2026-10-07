# ADR 0353: Isolated runtime OkHttp platform initialization

Status: Accepted

## Context

All five real Pixiv language sources failed browse and default-filter requests
in the minified Android runtime. A targeted run exposed PublicSuffixDatabase
resource loading failing because OkHttp's applicationContext was uninitialized.
AndroidX Startup in the main process does not initialize the service process.
The ABI and extension loaders intentionally use the canonical parent OkHttp.

## Decision

The Android runtime service calls `OkHttp.initialize(applicationContext)` at
the start of its existing engine bootstrap, before native driver activation.
The Context belongs to the host application, not an extension's payload.
Initialization failure uses the existing bootstrap failure boundary.
Source accounts, class loaders, transport, NetLane and Reader are unchanged.
No owner, client pool, queue, timer or retry policy is added.

## Validation

The existing platform ownership guard first fails without process-local
initialization and then verifies its position before engine/driver startup.
Real Kotlin compilation and the minified all-source rerun passed: each Pixiv
language source completed all 11 source steps, and the complete run passed
144 steps. Required-toolchain gates completed static/analyzer, 2136
Dart/Flutter, Debug three-ABI and 22 Rust checks. The targeted failing run
and reruns are preserved in the source-device-acceptance audit. An initial
intermittent manifest activation failure remains separately under diagnosis;
no fix for that event is attributed to this decision.

Official API: https://square.github.io/okhttp/5.x/okhttp/okhttp3/-ok-http/initialize.html
