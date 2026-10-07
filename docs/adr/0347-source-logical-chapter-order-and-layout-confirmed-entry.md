# ADR 0347: Source logical chapter order and layout-confirmed entry

Status: Accepted

## Context

Fresh device evidence exposes reverse Mihon boundary navigation and chapter reentry landing at an old viewport. Mihon emits newest-first source chapters, but its source ordinal was exported as oldest-first logical sequence. Cached geometry can arrive before ScrollPosition applies its new range.

## Decision

Preserve source list/object order and opaque ordinal-based identities; project oldest-first logical sequence separately. Plugin-host adapts persisted Mihon order for Home composition without Reader parsing identities. Other sources retain their existing sequence contract.

Chapter entry uses the existing Controller absolute request and layout acknowledgment. The explicit request supersedes queued idle anchors, first/last entry aligns to real scroll boundaries, and completion confirms target layout and a stable range. Real dragging retires pending commands; controller replacement fences old callbacks. Slider center alignment remains the default for explicit page selection.

## Consequences

No transport, source, retry, session or prefetch authority moves to Reader. Regression coverage includes cached-ratio arrival during chapter replacement, first/last reentry, source order compatibility, and existing drag/scrub ownership. Device verification must cover top and bottom traversal and return to the original chapter.

## Verification

Reader73/73, Home11/11 and executable Kotlin order regressions pass. The 14-55-08 Profile ring covers all four top/bottom return paths and confirms first/last entry rather than history. Final required-toolchain checks pass. Evidence: [chapter-boundary audit](../audits/chapter-boundary-trace-regressions-2026-09-30.json).
