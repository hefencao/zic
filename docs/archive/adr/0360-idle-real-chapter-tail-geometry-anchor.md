# ADR 0360: Idle real chapter tail geometry anchor

Status: Accepted

## Context

The intermediate Release trace enters previous chapters at indexes262 and232,
then later idle measurements report261 and231. A failing-first widget
regression narrows this to a viewport shrink: pixels stay200 while the real
maximum changes from200 to300. The ordinary top anchor preserves the old
viewport start but loses the real chapter tail. A first geometry-sum tail target
also fails device acceptance: ListView includes implicit system insets in its
actual scroll extent. The inset regression expects1056 but gets1000. Fresh
`08-16-38` confirms the drift precedes the control tap and has a35.555px layout
residual; controls reveal this drift rather than cause it in that run.

## Decision

During an idle geometry change at a distinct real maximum scroll extent,
preserve a semantic tail anchor with the existing layout-time geometry
correction. ScrollPhysics resolves it from the new ScrollMetrics maximum,
including system insets; page geometry does not own that maximum. A retained
slider center still takes precedence. Head/interior top anchors and fitting
chapters retain their existing behavior; active content motion is unchanged.
Implicit inset changes can update the scroll range without a Reader viewport,
ratio or DPR change. Physics also preserves the old real maximum in that case,
only for an idle Controller already reporting the final page with no pending
page/viewport command or retained slider center. Controller replacement and
explicit entry commands therefore keep precedence over an old physical tail.
This extends ADR0260's ordinary top anchoring only at a real idle tail and
preserves ADR0354's retained absolute slider center precedence.

No additional state owner, post-layout jump, timer, queue, worker or resource
eligibility gate is introduced. Reader remains a navigation/observation owner;
chapter identities, Pipeline, NetLane and all window/budget policies are intact.

## Validation and limits

The valid failing-first and after evidence live in
`docs/archive/audits/loading-chapter-plugin-regressions-2026-10-01.json`.
Regressions cover height shrink/growth, width, static/dynamic system insets and late ratio changes, zero idle
velocity, non-tail anchors and a fitting chapter becoming scrollable.
Existing late slider and active-motion regressions remain required.
Toolchain and device evidence are independent; correct initial entry alone
does not prove the tail survives a later control/system-bar change.
Final dynamic-inset Release verifies tails 263 and 233 across repeated controls;
the applied-layout revision also revalidates 68/68 and next chapter 1/198.
The gate and complete post-fix trace are linked in the regression audit.
