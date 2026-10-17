## Unreleased — state governance and device acceptance

- Complete scheduler-cancelled queued API/model requests without waiting for unrelated tasks and stop DeepL from retrying cancelled requests. Probe AArch64 CPU capabilities through a baseline JNI library before loading the DotProd-compiled Hy-MT runtime; incompatible devices report unavailable. Correct the settings label to describe automatic Japanese/Korean detection.

- Use independent pill choices for Reader source languages and indicator modes, with matching typography, height, padding and spacing. Size each option to its contents.

- Move the labeled translation indicator pill above the comic translation switch. Remove the switch's visible label while preserving its accessibility name and per-comic behavior.

- Add a direct segmented pill for per-comic always/processing-only/off translation indicators without replacing the translation session or restarting inference. Draw only the current stage icon, with a progress ring during work; show page numbers only in the app Debug mode. Processing-only mode hides terminal states and reappears for new work. Preserve existing visibility preferences and stage descriptions in accessibility and the settings sheet.

- Add Reader source-language chips scoped to each comic and remember bounded Japanese/Korean script detection per OCR model. Switch only the OCR recognizer while retaining its detector; keep shared translation models warm for up to 30 seconds after their final lease, drain them on background/memory pressure, and resume from durable results. Move cache JSON/base64 conversion and OCR artifact hashing into the storage worker. Reuse dense-mask geometry within each grouping pass to remove repeated flattening/scans from Reader entry, request/context assembly and overlay preparation.

- Make the Reader translation button tap toggle the comic preference and long press open settings; show the current page and processing stage at the viewport's upper right. Bind retained page overlays to late session initialization and configuration changes, preserve the session on enable changes, and replay the current viewport when enabling. Preserve the media subtree through paged magnifier entry/release and retain a complete translation layout while chapter font metrics prepare its replacement. Ignore repeated observations of the active translation task; verify content-cache reuse after closing and reopening the database.

- Move Debug diagnostics to the Home app title: tap opens translation testing, long press opens the expanded diagnostic items with translation first. Add direct translation settings and per-test languages. Preserve OCR line breaks and corresponding translated paragraphs instead of injecting literal pipe characters; version the local translation cache protocol. A bounded tagged whole-page Hy-MT trial took20.1s/21.1s on controlled Japanese/Korean inputs after fallback, versus8.3s/8.8s per-bubble; remove that slower experiment and retain independent bubble generation. Keep two controlled complex-bubble PNG fixtures with embedded source text for OCR quality reproduction.

- Preserve ONNX Runtime's JNI-created Java types in the translation plugin's consumer rules, fixing the first OCR call aborting in minified Android Release. Extend the APK check to require those original type names. Build the text-translation connection test from an explicit text unit and a sample in the selected language; automatic local tests use the model's declared source language instead of a fixed English sample or empty OCR geometry.

- Normalize a blank DeepL model_type to the engine's existing latency_optimized default for both request and cache identity. Device testing exposed that the optional settings field previously failed before sending a request; add a failing-first regression and keep unknown nonempty types rejected.

- Recheck the complete setup-following Reader action window on unchanged dev331 Profile:8.483498s/933 CPU samples includes actual drag,ballistic and Reader callbacks;267 UI frames peak at11.578ms and natural GC at7.519ms. Vertical exit raster19.724ms and a separate20.825ms exported frame remain failing. Corrected sched capture is a paged exit without that failure:15.243ms raster contains14.975ms running,not proof of the vertical cause. Fix test-only Perfetto input/ROI reporting errors,restore ordinary Release/Follow and overwrite current acceptance. SDK3.12.2 allocation-profile fields count current heap;neither these fields nor GC reclamation proves total allocation. Keep112 IDs/21 unfinished,retain unchanged2385/full-toolchain results and clean completed warm captures.

- Reuse the version-relation upsert within its SQLite store connection and close/clear the statement before connection retirement. Preserve discovery/proof/no-op revision and recovery after write failure or same-store reopen.31 storage tests and fresh2385/full gates/three-ABI Debug/Profile/minified Release/JNI pass;native121 retains unchanged inputs. Ordinary dev331 Profile completes warm refresh with0 downloads/failures and0 sampled upsert work;remaining prepares are relation reads. Entry build13.792ms,exit raster14.737ms and natural GC6.958ms meet the scoped component budget;different manifest preparation prevents a strict speed ratio. Release visually presents the actual page. Original entry/allocation/physical-display scopes stay open;overwrite current state and replace completed inputs.

- Fix quadratic gnd version parsing: lazy match length/elementAt rescanned anchors; the source adapter now traverses once, reuses patterns and yields after4ms/64 anchors with original cancellation. Preserve source order/date/URI and NetLane completion. Two failing-first regressions,62 adapter tests and fresh2384/full gates/three-ABI Debug/Profile/minified Release/JNI pass;Android121 retains unchanged native inputs. Ordinary dev330 Profile confirms refresh completion,no rescans and warm first frame123.321ms with0 downloads/failures. Observed wait15.379ms/raster17.621ms is not a strict speed comparison:related-manifest preparation differs. GC/GLES,allocation and physical display remain open. Restore Follow/ordinary Release and clean completed captures. Correct the accidentally removed Plan ballistic description and rerun all gates.

- Bound background source-version commits in their existing owners: SQLite skips unchanged relation updates while preserving first discovery/proof and real title/proof changes; empty mappings do not copy the canonical ledger; sequential commits yield after4ms/64 records and observe the original TaskControl without releasing admitted lane capacity. Three failing-first regressions and120 focused owner tests pass,as do fresh2382 tests/27 suites/analyzers,Rust25,all gates and three-ABI Debug/Profile/minified Release/JNI. Android121 retains unchanged Kotlin/native inputs. On ordinary Profilee324801c,matched source-ready warm return waits reduce46.783→25.831ms with0 empty-ledger CPU samples;current page first frame116.835ms,0 downloads/failures and version refresh completes. The cold-first route precedes plugin-host readiness and does not submit this refresh,so it is excluded from that comparison. Remaining version parsing/GC,entry/GLES/allocation and physical input/display remain open;all112 IDs/21 unfinished scopes are retained.

- Reconcile056/069 with current source-client authority: mandatory WNACG host-direct and untyped protocol-mismatch replay are superseded;actual source plans/readable runtime media and sealed-body scopes041/047/049 remain accepted. Do not weaken client eligibility or claim untested host execution.112 IDs now retain21 unfinished records. Capture complete9.779s ordinary Profile vertical entry/slow drag/fling/reverse/exit without action-time snapshots:117 drag/42 ballistic intervals,active UI max10.525ms,15 nonnested UI collections. Entry build23.442ms includes14.444ms GC;exit raster21.544ms is mainly GLES submission. Keep entry/exit allocation attribution,physical touch/visual and final display open;natural GC observation is not total-allocation acceptance. Correct nested-GC counting and remove obsolete paged/heap-stock captures. No production changes;current documentation/state gates pass,full2379/Rust25 and native/Profile/Release/JNI retain unchanged executable scope. Restore ordinary Release06945ef7/PID1561/Home,original direction and no forwards;retain only the current open fault input.

- Retire055's false durable metadata-response upgrade premise: historical dev159/dev160 and current ResourceCacheManager persist imageBytes only;typed catalog responses are memory-only and durable library snapshots keep their independent Home refresh/locator compatibility. Correct the misleading production/gate comments and chapter revision test,whose stale key previously differed in identity and namespace,then add memory-metadata/cold-owner versus durable-image and Mihon-only revision coverage.130 focused and fresh2379 full tests/27 suites/analyzers,Rust25,all gates and three-ABI Debug pass;Android121/Profile/Release/JNI retain unchanged executable/native scope.112 IDs now have23 unfinished records. Remove10 clean main-history worktrees,12 generated directories from two unique-commit worktrees and three stale worktree records,freeing about21.6GiB without relocating artifacts or removing dirty worktrees/unique source commits. No executable production behavior changes.

- Separate unavailable-input branches from actionable acceptance instead of treating all24 unfinished records as blocked. Correct the Plan gate so final physical-display observation does not prevent independent active/input/full-window GC checks; durable-cache upgrade and eligible host checks remain independent. One actual Mihon JM pull-refresh returns80 items in1.254s with no failure or verification;record its scope and remove that completed raw capture,without closing079/080 failure branches. Preserve all112 IDs,current accepted components and unchanged production inputs.

- Probe the genuine Roumanwu22 declared rouman5.com address once in an independent Profile package. Chapter loading selects ::1:443 and fails with ECONNREFUSED before Reader creation;public DNS returns public addresses,device VPN is active and hosts has no domain override. Resolution authority remains unconfirmed:do not blame Reader,claim DNS cancellation acceptance or bypass system answers. Preserve the original66-page manifest and accepted preference repair;remove the temporary package/APK/worktrees,restore ordinary Release06945ef7/PID30575/Home and update existing097 scope. All112 IDs/24 unfinished records remain;production inputs are unchanged.

- Correct inflated acceptance gates against the original requirements: JM's conditional single-SChapter response is not a mandatory missing sample, and actual WNACG GET/null-body plans do not require invented nonempty Cookie/POST variants. Preserve the genuinely unverified durable upgrade, eligible host-readable media and protocol fallback criteria. Device inventory still lacks210a3115. No production changes or new audit files;112 IDs/24 unfinished records and accepted component results remain unchanged.

- Recheck stationary Ani273/371 on ordinary Profile06bdc2b2/PID15894 without production edits: actual body,205.857ms tap-to-first-frame,871us exit reconcile and0 taskFailed. The17528576-byte current READY body skips downloading;two starts continue incomplete neighboring bodies. Retained CPU/GC timeline covers Reader frames with6.019ms max GC,while missing full-window edges prevents total entry/exit or allocation acceptance. Correct test-only ring/trace retention and current-heap interpretation,stop the completed stationary input and keep24 independent records open. Restore Release06945ef7/PID16727/Home;retain identical-input2377/Rust25/Android121/toolchain results and delete completed old private captures by exact paths.

- Fix Mihon source-managed preferences that persist a normalized value and return false to suppress the default widget write. The host reported rejection after persistence and skipped request-plan invalidation; exact-key readback now preserves source results while retaining validation and callback errors. Six regressions expose the two old failures. Genuine Roumanwu22 rejects invalid input, keeps normalization and permits same-value reentry; its subsequent chapter request times out before Reader creation, leaving097 lifecycle unverified. Fresh2377 Dart/Flutter tests,27 suites/analyzers,Rust25,Android121,all gates and three-ABI Debug/Profile/minified Release/JNI pass. External file-selector tests use temporary API34/ASM9.9/ByteBuddy Java25 compatibility only. Ordinary Release06945ef7 installs/Home/PID15419;user data retained. Clean completed helper and duplicate artifacts;112 IDs/24 unfinished records remain.

- Clarify the24 remaining records as unfinished scoped acceptance. Ordinary Release force-reload on72b presents fresh epoch1/frame0 at6.712s,before navigation at57.393s;already-active660→0→780 work does not verify016 admission. The independent Roumanwu21 Profile browse stops at127.0.0.1:443 before manifest/Reader;owners close and the package is removed. Recover an unchanged genuine21 第3話/66-page old manifest from the existing10-01 ZIC backup,retaining one private chapter rather than a whole backup. Original19/20 full pages are absent;new-source manifest,Reader generations and independent retirement097 remain unverified. Update current input conditions and stop repeating the failing endpoint. Current documentation gates pass;retain identical-input2377/full-toolchain results,112 IDs and24 unfinished records.

- Complete the catalog-update marker part of 023 on ordinary Release ec6f9e5a/72b08a1c: the real Roumanwu 要成為男子漢 title-search card shows the upper-left shelf marker/dim surface and an independent upper-right update marker. Correct the initial Home-versus-source-card test scope, remove the accepted Plan work and retain only the genuine unique-latest action. Seven retained Mihon APKs have direct single-entry metadata; thirteen retained previous promotions are cache hits without downloadStarted. The original 037 cover batch is incomplete in the archived analysis and its trace/package are absent from the inspected project/private directories. These inputs do not close 071/016/037 or establish new product defects. No production change; fresh full checks pass with 2377 tests, 27 suites/analyzers, Rust 25 and three-ABI Debug. Retain identical Profile/Release/JNI and native115 results; delete completed lookup payloads/captures, obsolete layout cache, temporary directories and Debug outputs. All 112 IDs and 24 unfinished records remain.

- Fix synchronous READY inventory indexing and repeated Home identity work exposed while alternating the local HalfLove comic and E-Hentai Ani history entries. Include index construction, candidate sorting and chapter grouping in the existing downloads-owned 4ms/64 event-turn budget; snapshot command records before yielding and preserve reuse proofs, ambiguity, ordering and cancellation. Share canonical identity and reverse aliases within one Home build; live card preferences still read current authority. Failing-first READY and catalog-growth regressions pass with fresh2377 tests,27 suites/analyzers,Rust25,all gates and three-ABI Debug/Profile/minified Release/JNI; native115 retain unchanged inputs. Profile samples show READY computation split into177 event messages,max4.139ms,despite408ms total wall time. Ordinary Releaseec6f9e5a on210a3115 confirms HalfLove22↔Ani377 stationary body/history; three captured taps reach body in108–165ms with0 failures. The initial entry was overwritten by the trace ring; cover-install first-entry seconds and final physical-display performance remain unverified. Update existing state and clean completed captures without expanding the24 independent unfinished records.

- Fix Reader transition stalls traced to UI-thread native frame/cursor/source destruction, repeated unchanged version authority rebuilds, snapshot requests and large resume-prefix CRC loops. Relinquish native handles to an independent process reclaimer only after exact decode/write exit, with an off-UI composition drain; preserve retained handles and scheduler capacity. Skip unchanged discovery rebuilds, coalesce uncaptured snapshots, prune unreachable version paths and hash bounded chunks off-UI without changing verified mapping, cache or cancellation authority. Fresh2376 Dart/Flutter tests,27 suites/analyzers,Rust25,Android115,all gates and three-ABI Debug/Profile/minified Release/JNI pass. Same424-page Ani/page80 Profile exit reconcile falls20.864→0.875ms; the first5s have no frame gap over100ms, while first-frame latency is not claimed faster. Ordinary Release4ff852df confirms stationary body, return/history and0 failures, with0.441ms exit reconcile. Update current state, retain24 independent unfinished records and the original fault input, and clean completed CPU/helper/duplicate trace/build outputs.

- Put migration/title-search controls at the bottom and share the source browser's horizontal source bar, including an All pill. Exact-title and empty-result filters toggle directly; native ID switches the existing single-source input without a dialog. Confirmed versions expand inline as an update using common version rows; original refresh, raw identity, pagination and final comparison owners remain. Nineteen related regressions and fresh2371 tests/27 suites/analyzers/Rust22/all gates/three-ABI Debug/Profile/minified Release/JNI pass; native115 retains identical inputs. Ordinary Release70ac8752 confirms both layouts, inline versions, All/direct filter toggles and native-mode input/IME; no ID or migration is submitted. Return Home/PID23084/no forwards, update existing state and retain24 independent unfinished records. Delete completed Debug/Profile and duplicate build outputs, retaining current installable Release packages and named UI screenshots.

- Simplify source migration: current comic and confirmed versions precede search; native ID uses an action in the search row. Migration and title search share source selection, empty-result/title filters and the source browser's colored pills with selected JS/puzzle indicators. Preserve original candidate identity, source pagination and confirmed migration ownership; reselecting a completed group presents its retained result immediately. Eleven focused regressions and fresh2370 tests/27 suites/analyzers/Rust22/all gates/three-ABI Debug/Profile/minified Release/JNI pass; native115 retains identical inputs. Ordinary Releasec3c55a10 confirms both layouts, source-pill selection, filter toggles and the migration native-ID entry; filter data branches are covered by widget tests. Restore Home/PID22117/no forwards, update existing state and retain24 independent unfinished records.

- Complete057 mirror identity acceptance on ordinary main Debug: BASE, API2 Apply, reentry and API1 restoration retain12 valid original object references, native process/session/runtime IDs and open session/connection/channel flags. JM transport generation advances twice; EH is unchanged. Use the standard Dart VM client and stable source IDs after correcting a display-name matcher in the temporary observer; no production change. Only completed actual Web login remains in057. Compact four accepted State contracts without changing scope/statuses, restore ordinary Release499ee89d/PID20421/Home/unlocked/no forwards, and delete completed helper/Debug/XML outputs. All112 IDs and24 unfinished records remain.

- Confirm the SDK36 device lacks the android.network_packets producer and retain013 independent receive-time acceptance until that observation is available. Distinguish settings transport generation from097 chapter revision/carrier input. Clarify existing migration durability: equivalence registration does not replace HomeSourceMigrationTransaction target-exact materialization. Mirror observer attempts stop before BASE/settings changes, so no new057 pass is claimed. Restore Release499ee89d/PID13719/no forwards, clean completed Debug outputs and four closed native-retirement cache directories, and retain112 IDs/24 unfinished records. No production change.

- Record partial057 without a production change: JM API1->2->1 Apply/readback passes; a separate API2 checkpoint preserves12 valid object references, advances JM resource generation and keeps EH generation. Post-Apply/final-restoration identity, native IDs/closed flags and completed Web login remain unverified. Restore ordinary Release499ee89d/PID32478 with no forwards; foreground/Keyguard were not rechecked. Retain112 records/24 unfinished, remove duplicate validation history and delete completed Debug/temporary XML outputs by exact paths.

- Recheck the ordinary main-entrypoint migration/search and EH version inputs without a production edit. Profile227ab457 opens the existing Ani details-title route with the exact title and grouped live search; no corrupted IME query is submitted. The current EH result does not contain the shelved old version,so no update action is claimed. Read the existing gzip Home snapshot in memory:the complete Ani family has56 nodes/151 relations/46 terminals and131 mappings,106 with verified intervals. Correct the initial saved-only subgraph/incorrect proof-key count;do not invent a unique latest from dates or display order or recreate already available proofs. VM projection inspection stops at an authentication error and cannot prove Home's full update list. Keep023/099 partial with explicit remaining criteria,retain all25 unfinished records,restore ordinary Release3dbc12fb/PID28421/Home and clean completed artifacts by exact path. Migration/Reader/source/cache/NetLane owners remain unchanged.

- Verify099 inactive different-provider partial on Android Profile78d1f283 using the existing source/native Reader fixture. Three fresh compositions restore canonical A→B→A prefixes1320216→1385752→2509314 bytes; local frame0/partial looping precedes both held206/64KiB overlap continuations. Each URI establishes its own ETag,epochs stay unchanged,complete exact bytes/CRC and new native frames2/3 pass,three HTTP/TCP peers and all owners exit with308 events/0 failures. Correct only the fixture's120ms eight-frame/3s assertion for its600ms partial input. Also replace obsolete Architecture READY-only/per-page alias restoration with the current compact canonical authority;the strengthened existing dev210 gate fails on the old text and passes after correction. Production code stays unchanged. Required2364 tests/27 suites/analyzers/Rust22/all gates/three-ABI Debug,fixture Profile/strict analysis/JNI pass;ordinary Profile/Release/native115 retain identical inputs. Restore Release3dbc12fb/PID25960/Home,remove completed outputs and retain099 only for real EH proof/update,with25 unfinished records.

- Accept the bounded099 cold Reader/canonical authority/live-promotion components on Android Profile01f93a6e with the existing Home fixture. A held controlled version lookup does not block the ordinary cold Reader;authority precedes acquire by15.3ms. While both native Readers remain mounted,successor82 promotes a CRC-verified627306-byte body and previously unacquired old80 presents through the same physical owner with zero old-URL requests. Seven checks pass,0 taskFailed,user stores unopened and temporary owners drained. Correct the device input staging order/quoting after an input-only failure;no production edit. Fresh required2364 tests/27 suites/27 analyzers/Rust22/all gates/three-ABI Debug,fixture Profile/strict analysis and JNI pass;ordinary Profile/Release/native115 retain identical inputs. Restore ordinary Release3dbc12fb/PID8643/Home,remove completed host/device outputs before Release closes run-as,and update099 to partial. Real EH proof/update action and cross-provider cold partial remain open;25 unfinished records are retained.

- Align the remaining099 acceptance and duplicate Spec restoration paragraph with current canonical media projection. Plan/state still demanded the removed per-page alias-restored event while production and dev210 explicitly forbid that owner;the older Spec also restricted registration to already-READY carriers,contradicting its canonical physical contract. Describe HomeLibrarySession authority before acquire,version-reuse-authority-ready/canonicalDirect,source-verified future intervals and later promotion through the same physical identity. The existing gate fails on the stale Plan then rejects its recurrence in current Plan/state/Spec. Preserve exact provider/binding authority and all25 unfinished device scopes;no production edit or new device acceptance. Completed host025 inputs are deleted;its2243-byte private device result awaits the next necessary Profile session because restored Release is not debuggable,without a cleanup-only reinstall.

- Close025 with actual installed EH source confirmation and post-replacement production UI on Android Profile1f663194. The existing fixture queries the mounted browser raw/canonical shelf projection,then opens exact live-source old/target details and checks visible keyed shelf actions:old off shelf,target in shelf,one actual old raw identity. It fabricates no native model,browse response or relation and proves no physical gesture/search-card rendering. User payload/manifest/projection stay unchanged,library/index unopened and temporary root is removed. Fresh required2364 tests/27 suites/27 analyzers/Rust22/all gates/three-ABI Debug,strict fixture analysis and three-ABI fixture Profile pass;ordinary Profile/Release/native115 inputs are unchanged and retained. Restore ordinary Release3dbc12fb/PID29367/Home,close025 and its Plan work,update074 alias component and112 states to74 device/11 toolchain/2 superseded/18 partial/7 pending. Clean completed task outputs;25 unfinished records remain,no production edit.

- Complete actual JM1441640 Venera-to-Mihon cross-source migration through the redesigned default-title aggregate search and production Home/details comparison,risk acknowledgement and confirmation in isolated SQLite. Profilead9222ad verifies0 exact/1 sequence-only,target native identity/preferences/own admission acknowledgement,origin state retention,no foreign version relation and drained journal;payload/manifest/projection stay byte-unchanged,user library/index unopened and temporary root removed. Correct only the fixture:source-declared public title slugs identify the input without rewriting native/cache identity,and first target admission acknowledges its own version rather than requiring an empty ACK. Add bounded target/timeout observations to the existing result. Required2364 tests/27 suites/analyzers/Rust22/three-ABI Debug plus strict fixture/Profile pass;ordinary Profile/Release/JNI/native inputs are unchanged and retained. Close024,remove its Plan work and update112 states to73 device/11 toolchain/2 superseded/19 partial/7 pending. Restore ordinary Release3dbc12fb,clean completed task outputs and retain26 independent unfinished records;no production edit.

- Unify detail migration and same-source versions while preserving discovery and its update badge. Reuse aggregate search for editable queries and grouped cover/title candidates, with source pills that distinguish same-name Mihon/Venera sources; keep native ID input in an advanced single-source section and clear it on selection changes. Pass exact source-returned identity to the existing comparison after the selector route finishes. Reuse the original read-only version Future, ignore late dialog publication after exit and retain confirmed-version access from disabled-source details without enabling or browsing that source. Make the badge decorative so the action keeps its accessible name; align stable documents with the unified entry. Failing-first exit and disabled-source regressions pass; required2364 tests/27 suites/analyzers/Rust22,three-ABI Debug/Profile/minifiedRelease/JNI and strict live-fixture analysis pass with3 existing quarantines;native115 retain identical inputs. Actual ordinary Release3dbc12fb verifies the named action,six source pills,advanced entry and return Home;current candidates are not visible and no confirmation is performed. Correct the JM fixture to obtain source-native models via supported URL search,accept the declared trailing-slash Web path and verify the exact UI-selected model. Its old manual-model test stopped after IME corruption,before submission or confirmation;exact temporary outputs were cleaned and cross-source acceptance stays open. Source/library/transaction/cache/Reader/network owners remain unchanged.

- Fix source-management action semantics: visible application settings and runtime properties/login buttons were merged into the row toggle by SwitchListTile,leaving Android XML with only one Switch. Use ListTile with an independent named Switch and existing action callbacks;source-row tapping still toggles. The existing source-browser suite now checks distinct semantics and actual action routing without enabling/disabling the source when opening either settings page. Ordinary Release98dc6501 verifies both Mihon entry routes and unchanged enable states;declared mirror choices vip/ink remain unchanged.2360 tests/27 suites/analyzers and all gates pass;only failed Debug asset build is resumed with private Java temporary space,then Rust22 passes. Fresh three-ABI Profile/Release/JNI pass;native115 retain identical inputs. No source/network/cache owner change.

- Close075 at its original exact-versus-sequence-only migration criterion:accepted Android300 physical SQLite/file checks prove target native identity,exact state transfer and no sequence-only progress/read state/artifact even with media proof;actual live EH confirmation additionally verifies one exact transfer. Keep cross-source entry024,old raw alias UI025 and live mapping099 independent. Remove duplicated real-origin callback/phase work already covered by the accepted three internal interruptions and five durable boundaries.27 historical records remain;no production change or repeat of passed tests. Extend only the existing live fixture for the actual JM pair,using the declared Venera locator and installed jinmantiantang package. Final Profile2a7c85ef stops before migration UI on the target plugin mirror-selection/restart instruction;no migration verdict. Native plugin settings retain their normal package/source namespace;temporary payload copies do not isolate them. Final strict analyzer/Profile and required repository/platform/documentation gates pass;ordinary Release restored and completed results/test APK cleaned by exact paths.

- Accept actual installed E-Hentai same-source confirmation through production Home/details controls and isolated SQLite:44 freshly declared candidates,424 origin pages and one exact chapter preserve progress/read state/preferences; old metadata/shelf cleanup,source relation and journal drain pass. Correct only the fixture’s unique-successor assumption and feedback; migration allows explicit declared-version choice. User library/index remain unopened and original payload/manifest/projection unchanged. Cross-source,alias,positive sequence-only/artifact and notifications stay open;28 historical records remain. Fresh required2359/27-suite/analyzer/Rust22/three-ABI Debug and final strict fixture/Profile/device checks pass; unchanged ordinary packages/native/JNI results are retained. Restore ordinary Release and clean exact completed outputs; no production edit.

- Reconcile039 and049 against their original completion criteria: ordinary four-case Home filtering/signal preservation and negotiated source binary file response/lifecycle are already verified. Close those records without production edits or repeated device collection. Keep actual first-admission/later notifications in040, successor actions in023/074 and client/mirror/POST plus requested allocation/GC/original19/20/display work independently open. Correct016’s observation to already-active promotions rather than claiming an inactive admission. All112 IDs remain, with28 unfinished records; parent acceptance is incomplete.

- Close041 with actual installed WNACG HTTP source plans and unmodified runtime delivery:21,122-byte cover and1,550,704-byte page both decode without retry. Keep prior ordinary browse/details/eight-page Reader acceptance. Align the test with Spec’s domain-independent cleartext contract: the changed historical img*.wnimg*.ru host remains an observation, rather than a completion gate. No production edit; strict fixture analyzer/Profile and actual device checks pass, ordinary Release is restored and exact completed outputs cleaned.30 historical acceptance records remain.

- Preserve the actual Mihon source header UA in ordinary browser descriptors; use the existing fallback only when missing or blank. The old mobile projection reproduces an empty WNACG list and known-comic chapter failure. Its owner regression fails before repair; actual browser/settings/rejected-and-successful same-package transactions and final Release main list pass, closing070. Fresh required2359 tests/27 suites/analyzers/Rust22,306 gates, six ordinary packages/JNI and native88 pass; retain27 unchanged native results. Restore user files/snapshot, clean completed task outputs, update31 unfinished records and commit this owner boundary. Cloudflare provider-UA and Reader/network/cache policies remain unchanged.

- Reconcile005 first-new-output cost with accepted020 actual Reader/native/Texture handoff: blit3087us, schedule1313us, deadline miss0 and first frame67967us. Remove the duplicated timing work from Plan, retain fast-scroll visual/content composition as partial and keep all112 IDs/32 unfinished records. Original conditional ballistic investigation is not an added first-cost exit criterion; no production change or repeated device collection.

- Fix Mihon first-request browser Cookie/UA handoff reading the payload directory: give only NetworkHelper the host applicationContext while keeping plugin Application/resources/preferences isolated. The actual installed WNACG1.6 source client fails before repair; after repair two production native-driver creations reset observed imports before each first physical HTTP request and synchronously send the latest snapshot pair with exact PNG bytes. Close072, keep genuine Cloudflare/Binder/origin conditions separate. Fresh required2359/27 suites/analyzers/Rust22,306 gates, three-ABI Debug/Profile/minifiedRelease/JNI and affected native86 pass; retain27 identical native results. Install ordinary fixed Release106c4ab3/PID2041/Home without forwards/probe, preserve source files/user stores and clean exact completed temporary outputs.32 scoped records remain; no Reader,NetLane,cache,retry,DNS,identity or native worker policy change.

- Close052 using actual installed Venera/E-Hentai1.1.8 cold activation and two deliberate physical Service deaths through the existing Binder entry. The original pending object,request1 and encoded payload survive generation1→2 with one activation/two binds; the first case establishes the real source session, the second settles once terminal with no third bind. Source files remain unchanged and user library/index stay unopened. Production APKs are unmodified; SDK compile/sign checks and EH2 pass, ordinary minified Releaseb766acf9/PID27035/Home is restored without forwards/test package. Reuse identical required2359/native113/three-ABI production validations, refresh current gates/state, remove completed Plan work and exact temporary captures.33 scoped records remain; physical kills do not diagnose spontaneous crash/LMK.

- Fix same-epoch encoded-source replacement: DecodeSession validates the backing instance before late frames/errors and retires old continuation state before the replacement frame0 prefix check. Old frames are disposed and cancellation waits for the original cursor Future. Temporarily hidden unchanged sources and their valid per-frame hints remain valid. Four failing-first cases,38 decode/55 related tests and two actual isolated native replacement/prefix/frame0 Texture cases pass with0 taskFailed. Ordinary Release cached273/371 hits12,797,548B canonical READY and presents without gestures; its exact page has0 downloadStarted, while three unfinished neighbors legitimately resume. Fresh required2359 tests/27 suites/analyzers/Rust22, three-ABI Debug/Profile/minifiedRelease/JNI pass; native113 reuses identical Kotlin/native inputs. Final ordinary b766acf9/PID24186 installs and opens Home, with no forwards/test package. Preserve097's accepted TTL/LRU/native lifecycle scopes as partial, retaining only genuine source-revision/carrier retirement.34 independent scoped records remain open. No Reader/network/cache/worker policy change or new evidence file; completed captures/task tmp are removed.

- Reconcile071 with already accepted direct-class/single-entry Android APK inspection and activation rather than retesting it. The retained original JM manifest has one direct keiyoushi.source.Generated class and scalar extensionLib1.6. Current primary extension-source inspection supplies no suitable resource-referenced/multiple-entry payload; retain only those actual inputs as remaining acceptance. No production change, new APK, device run or evidence file. Current65 device/25 partial/9 pending still means34 unfinished scoped records; existing required2354/ordinary package/device conclusions remain valid.

- Close020 at the actual high-resolution current-handoff criterion. Extend the existing isolated Reader/native entry without changing production: while a4096×4096 non-current lossless WebP physically decodes, the mounted ReaderController requests page6 and new current frame0/Texture/first-frame arrives in67,967us. One Rust fragment phase proves old execution through both the command and new frame; the cancelled cursor retires after the original Future, late frames are disposed and all sources/cursors drain with0 taskFailed. This does not measure finger latency or final physical display. Fresh required2354 tests/27 suites/analyzers/Rust22,306 gates, three-ABI Debug and isolated/ordinary Profile builds pass; prior minifiedRelease/native113 retain identical inputs. Ordinary c57c36d7/PID20614/Home remains unchanged. Remove completed Plan work, bound runner command samples, collect logcat only on failure and remove completed inputs/captures. Current65 device/24 partial/10 pending means34 unfinished scoped records.

- Fix a retired decode callback reading its disposed native source after force reload. DecodeSession now checks the original cancellation, session/demand and Reader-local ingress epoch before either typed or untyped error classification; retired errors cannot create a failure or prefix retry. Six lifecycle regressions fail on prior code and all33 decode cases pass, including existing current-error classification and cursor-return capacity assertions. No Reader, transport, scheduler, native worker or lifetime owner change. Fresh required2354 tests/27 suites/analyzers/Rust22,306 gates, three-ABI Debug/JNI and six ordinary packages pass; native113 reuses identical inputs. Ordinary EH273 actually adopts1,112,520 physical bytes, resets the same epoch0-to1 once, presents without another gesture and commits17,528,576 fresh bytes to canonical cache with0 taskFailed. Frame0 follows the recovery event by1.530s; that event is after old transport exit and does not measure full touch latency. Close the affected borrowed-reset/retired-error scope, keep35 independent records open, delete completed captures and leave ordinary c57c36d7/PID20614/Home installed with no forwards.

- Fix force reload after direct physical-partial adoption: a completed session reset already removed the records, but repeated invalidation rejected its still-valid borrowed lease. Check missing canonical READY/partial records before body mutation guards and reuse the lending store's replica cleanup when destructive reset removes canonical READY. This also prevents old unreferenced final bytes from blocking fresh automatic cache handoff. Three important partial/completed/pinned regressions reproduce the old failure and pass with170 existing related cases; existing records still reject external deletion and pinned exact bytes survive. Fresh required2348 tests/27 suites/analyzers/Rust22,306 gates, three-ABI Debug/JNI and six ordinary packages pass; native113 reuses identical inputs. Ordinary EH272 resets once, renders stationary and completes15,105,284-byte cache handoff. Cold-entry admission fell out of the bounded trace, so actual adoption is unverified; a retired decode callback exposes a separate disposed-source failure. Release d6cf7005/PID11279/Home installed with no forwards. Production changes stay within the existing persistent store, with no Reader, scheduler or session lifecycle changes.

- Fix response teardown losing the native cancellation handler or waiting forever for an async body. The rhttp owner shares its termination/read Futures and ends intentional typed cancellation normally; DownloadJob starts the original physical abort before joining subscription and discard, including body-watchdog cleanup. Two important lifecycle regressions fail on old cleanup, then all44 job cases pass. Final Android pressure Profile0f075244 passes both affected branches,13 HTTP/139 events, partial preservation and current same-response read grant during retention exit, with0 uncaught errors/taskFailed and all physical peers/owners closed. Fresh required2345 tests/27 suites/analyzers/Rust22,306 gates, three-ABI Debug/JNI and six ordinary packages pass; native113 reuses identical inputs. Restore ordinary minified Release84006f31/PID5671/Home, update existing state/docs and remove completed captures. No scheduler/retry/cache/framing/worker/dependency changes;35 independent acceptance records remain.

- Close010 with the corrected Android pressure-only entry: two cases,13 actual HTTP requests,139 events and0 taskFailed. Typed body-read preemption preserves131072 bytes; current resumes its original response while another retention task is still physically active, and typed inactive eviction preserves196608 bytes. Every TCP/composition/source/temp owner closes; default NetLane and production code remain unchanged. Preserve this scheduler conclusion while independently investigating11 raw native cancellation diagnostics in049. Restore ordinary Release4dafc146/PID23224/Home, remove completed010 Plan work and update64 device/25 partial/10 pending,35 unfinished records. Reuse unchanged strict-analyzer/three-ABI Profile/full-toolchain results and refresh documentation/state gates.

- Add one mode to the existing source/native acceptance entry for the two remaining010 pressure branches, using real source HTTP bodies and the unchanged default NetLane. Observe typed destructive preemption/partial preservation and current original-response read grant during retention task exit; skip already-accepted capacity/native/READY cases. Initial Android run reaches six headers/leases but stops at its16KiB-prefix preparation assertion before either pressure branch. Correct only test input/framing assumptions: provide128KiB server prefix and check actual nonempty authoritative bytes, then advance from the actual server cursor. Strict analyzer, corrected three-ABI Profile and all306 repository/documentation/ownership/platform gates pass; device rerun remains unverified after the fixed operator exhausts quota. Preserve36 unfinished scopes and every accepted contract, restore ordinary Release4dafc146/PID6861, and keep only61KiB of current failed-result/trace/host-log inputs. No production or scheduler change.

- Close018/091/093 at their actual ordinary Profile Reader criteria:374ms forward/back plus cross-Reader switching retains original responses; two receiving pages preserve8,632,980 bytes outside the directional7/3 window and reattach after2.718/3.904s without another downloadStarted, then complete. Correlate delivered chunks, aggregated ingress, source/decode/deadline/presentation through partial and complete154-frame animation. Do not turn missing destructive pressure into another gate for these passed scopes; independent010 races,016 admission timing,020 high-resolution, wire/DNS and final-display work remain. Three observed resets are explicit force-reload commands, so clarify the existing UI skill to inspect a missing transient result before repeating any state command. No production change or repeat of passed scenarios. Update current63 device/26 partial/10 pending,36 unfinished records; restore ordinary Release4dafc146/PID3695/Home and delete completed captures. Reuse the fresh2343/full-toolchain/six-package validation from the identical Home production inputs.

- Fix Home artwork remaining unavailable after source recovery and being recreated by a changing raw comic/resume navigation key. Subscribe only the cover subtree to the existing source projection, keep healthy/pending requests and make canonical artwork a sibling of the current interaction target; preserve the local startup telemetry selection. The pending/painted regression fails on prior code, then all32 library UI cases pass. Actual Android cold two-process8 checks and combined updates/shelf/history/alias/enrichment/background3 checks pass through production owners and isolated stores. Close063/066/082 at these scoped criteria;39 records remain. Fresh required2343 tests/27 suites/analyzers/Rust22, three-ABI Debug, six ordinary Profile/minifiedRelease packages and JNI pass; native113 retains identical inputs. Ordinary Release4dafc146/Home is restored. No Reader/cache/transport/NetLane/runtime or worker change; update existing state and delete completed test captures.

- Fix Android13+ system Back bypassing the browser's legacy handler: a loaded ordinary WebView returned cancellation instead of committing its snapshot and returning success. Register an Activity-owned platform callback, reuse the existing history/completion entry and unregister on destruction; no Reader/network scheduling or snapshot-policy change. Four Back regressions fail before repair and pass alongside the existing eleven capture/probe assertions. Actual Profile3726a0ce applies two UAs through real settings and passes all ten general/Reader/repository/WebView/explicit-source checks, with four successful browser returns and exact snapshot restoration. Mihon1.4/1.6 production NetworkHelper/OkHttp priority adds ten passing assertions. Close046;42 original records remain. Fresh repository/docs/ownership/platform/Kotlin gates, affected analyzers, three-ABI Debug/JNI and six ordinary packages pass; reuse identical prior2342/Rust22/27-suite/analyzer/native113 inputs. Ordinary Releaseeeaaefa5/PID2393/Home restored; completed results/helper/XML/backup cleaned exactly.

- Close047 at the original source-client ownership criterion: selected actual Cookie8/MihonClient6/FailureRetry6 and production-helper/semantic owner regressions cover stateless host streaming, redirect/Set-Cookie handoff, unknown client capability and bounded typed rejection/replacement without another retry owner. Remove the invented requirement for every origin/client/HTTP permutation; keep exact independent real-origin/client/generation/performance scopes open. No production change or repeat of those passed device cases.

- Remove the unregistered, uncalled plugin-host MihonLoginActivity and ExternalLoginSnapshotStore declarations left behind by the dev.86 network-ownership move. Repository-wide production/test/export/documentation review finds only the two mutual declarations, an ownership guard and historical records; the current runtime uses network_bridge and exports no legacy helper. Preserve old user preferences and current browser data. Extend the existing dev.86 guard to reject these obsolete declarations and document the single owner; no browser/runtime/transport behavior changes. Fresh all repository/docs/ownership/platform/Kotlin/source-build gates, native86 and three-ABI Debug/Profile/minifiedRelease/JNI checks pass; reuse identical c2aba247 Dart2342/27 suites/analyzers/Rust22 and native27. Final minified Release remains byte-identical3baf5c68, already installed, so no repeated device run. Current44 remaining records are unchanged.

- Fix the browser completion/capture lifetime in the existing NetworkBrowserActivity. The real WebView Boolean ready result was compared to a string, leaving a completed page open; unfinished Back/destruction and late old-Activity capture also advanced the prior handoff revision. Capture only a completed ordinary document or stable verified document, submit Cookie/localStorage/provider-UA together, await that commit before success, and fence finishing/destroyed/navigation-stale callbacks. Seven lifecycle and four probe regressions fail at their corresponding old defects and pass after repair. Actual Android Profilebad0a9d1 passes clear-document completion, immediate Back and Activity interruption with zero changed fields/revision delta; restores the original snapshot exactly without opening the user library/index/source runtime. Close081, retain genuine challenge acceptance076, correct already-accepted nine-plugin/32-session work in057, and keep Reader/transport/NetLane/source state unchanged. Fresh required2342/27-suite/27-analyzer/Rust22, three-ABI Debug/JNI and six ordinary Profile/minifiedRelease packages pass; native113 reuse unchanged unit inputs. Ordinary Release3baf5c68/PID5807/Home installed, forwards empty; completed results cleaned exactly.

- Close011/098 with two actual Android physical/exact-authority cases using existing source/chapter/reader-scope consumers. B joins A receiving at4096 bytes, reads627306 exact pinned bytes equal to origin and adds no A durable copy; late proof preserves two demanded owners, and a fresh equivalent chooses one preferred promoted owner without a third request. Three actual HTTP/TCP peers and all owners exit,73 events/0 failures. Correct retired ambiguous-rejection wording from current Spec without changing production or claiming UI/native frames/real version discovery. New three-ABI Profile fixture/strict analyzer/runner gates pass; reuse unchanged d1d875fe required2342/native113/six ordinary inputs and restore ordinary Release/Profile. Remove completed Plan scopes, classify the remaining version/performance section by owner, clean completed captures and update54 device/27 partial/18 pending,45 open records.

- Reconcile original completion criteria for021 Venera cancellation,048 whole-repository resource entry audit and062 same-Mihon canonical artwork namespace. Existing actual pressure/held-HTTP/EH attribution, fresh owner gates plus selected traces, and real JM description0->39/three-surface62333-byte same-key observations already satisfy those scopes. Remove invented all-origin/all-field/replacement permutations from their remaining work, preserving independent wire/DNS/client/generation/Home-combined-state criteria. No production change or repeated device run. Remove completed Plan lines, bound the explicit remaining scenario groups, and update52 device/11 toolchain/27 partial/20 pending,47 open records; parent acceptance stays incomplete.

- Fix027/028 catalog refresh reacquiring all healthy/pending source-card cover Futures before an unchanged response. Retire only current-Future observed source/decode failures; keep exact one-shot corrupt-artwork recovery and late-callback fencing. Existing regressions fail before repair, then verify one pending/healthy load, stable Image State and source/decode retry boundaries. Ordinary Roumanwu details-return/catalog comparison reduces12 duplicate loads/firstframes to0 with127 events and0 failures. The actual post-fix local-details source refresh completes7 chapters; no remote-only assumption or repeated test. Fresh required2342/27 suites/analyzers/Rust22/three-ABI Debug/JNI and six ordinary packages pass; unchanged native113 results reused. Remove completed Plan work, close scoped50 device/30 partial/20 pending (50 open), clean the two completed exports and leave Reader/cache/gateway/transport/NetLane untouched.

- Fix073 rejected Mihon APK diagnostics: metadata inspector keeps package, key names, declared/normalized ABI and resolved entry text in the original scan/error message, with explicit missing values and no unrelated metadata export or source activation. Actual installed non-extension APK fails the context assertion before repair and passes3/3 after; acceptance stays rejected. Native bridge86, fresh required2342/27-suite/analyzer/Rust22/three-ABI Debug/JNI and six ordinary Profile/Release packages pass; unchanged native27 reuse prior results. Remove completed Plan work and update bounded state to48 device/32 partial/20 pending,52 open. Keep the fresh unchanged-cover refresh regression027/028 open for a separate fix.

- Close009 with actual default NetLane saturation/native/cold-body acceptance: normal5, current-only6, five demanded parked responses retain all leases while read permits fall to1, and cold durable Reader consumes no remote resource or stored-body copy. Current resumes the same TCP/session/epoch/task and commits actual bytes; all6 peers/owners exit, with7 HTTP requests and0 failures/evictions/preemptions. Correct test-only safe-boundary and64KiB commit-quantum input assumptions; production stays unchanged. Narrow010 to unverified delayed-exit/destructive branches, remove completed009 Plan work and update bounded state to47 device/32 partial/21 pending,53 open. Bound runner command samples to avoid duplicating raw captures, then delete completed outputs directly. New three-ABI Profile fixture/analyzer pass; reuse identical-input full2342/native112/ordinary packages and run current documentation/state gates.

- Close103 current8-source UI order/pagination at fixed criteria: remaining Junmeitu and Roumanwu popular each pass actual1->2->1 with changed cards and stable identity; final596-event trace has10 browse completions and0 failures. Preserve source-returned empty/exhaustion and earlier section/backend acceptance. Built-in MangaDex declares no popular section and installed Pixiv exposesen only, so remove these invented pending criteria instead of changing production. Restore original source flags, delete completed exports exactly and stop accepted paths. Current46 device/32 partial/22 pending means54 open records. Reuse the just-passed a322b03e full gate against unchanged code; rerun current documentation/state gates.

- Close012 through actual Range EOF/mismatch, full-body catch-up EOF and malformed network-only sidecar branches. Every branch preserves1,320,216 exact playable bytes, epoch and native looping while network work retires; correct only fixture POST/Range input and durable-index target assumptions. Run the last metadata branch independently instead of repeating three passed cases. Close original029 Filter schema/default and conditional053/092 diagnosis policy at their scoped criteria, remove stale completed008 Plan work and reject completed scopes left pending in Plan. Additional real JM/Pixiv(en)/紳士漫畫/Junmeitu category/popular paging updates103; remove the invented built-in MangaDex popular and uninstalled-language criteria, leaving actual Roumanwu popular. Current45 device/33 partial/22 pending means55 unfinished records, with performance/DNS/capacity kept independent. Production code is unchanged; update bounded state and clean completed outputs exactly.

- Close008/101 with two independent Android native partial cases: exact/verified-equivalent misses do not materialize durable-store sessions, actual old owners retire before new owners adopt1,320,216 unsealed bytes, and local hydration precedes network admission. The new origin supplies less than a frame while native frame0/DecodeSession looping resumes from durable bytes. Two physical cancellations keep the exact prefix; mark012 partial and retain EOF/mismatch/network-metadata cases. Reuse accepted resolver Network4/Cookie8 basics without adding unrelated redirect criteria. Extend only the existing fixture/runner, remove completed Plan work and clean exact device/private test results before restoring ordinary Release. Production code is unchanged; current44 device/35 partial/24 pending means59 unfinished scoped records. Fresh required2342 tests/27 suites/analyzers/Rust22, three-ABI Debug/Profile fixture and source-built JNI gates pass; native112/six ordinary packages reuse identical production inputs.

- Close019/085–087 at fixed input/assertions: real EH Release partial/full/reverse gestures preserve identities and ordering, and the existing native WebP source fixture now fixes current at zero frames before an actual partial drag. Target independently presents, current reaches3 frames before neighbor deep refill, and reverse keeps physical sessions/epochs with two origin requests and joined teardown. Correct a test-only assumption that a sampled coverage trace must precede the per-frame transition decision; production behavior remains unchanged. Use a separate mode so accepted six file-body cases are not repeated. Update bounded state to42 device/36 partial/25 pending, remove completed Plan items and clean completed captures; independent capacity, cold partial, network and performance criteria remain open. Required2342 tests/27 suites/analyzers/Rust22, three-ABI Debug/Profile fixture and source-built JNI checks pass; ordinary packages/native112 reuse unchanged production inputs.

- Scope EH loading acceptance to actual tested paths. Ordinary Profile139 toolbar reload starts at0 bytes and presents in5.343s without another gesture. Ordinary Release142 verifies playable-prefix parking/resume. Fresh Release139 parks at256KiB with no decoded frame while142 is current, then resumes the same response36ms after return; first frame arrives126ms after current, with actual3/20s images and no failure or duplicate download. Decode reads2.875MiB after resume; its17.454s body gap overlaps parking. Close017 using existing real-source stage/body observations: the conditional trigger for later transfer-pressure investigation must not expand its completion criterion. Preserve independent wire013, DNS089, drag085–087 and performance requirements. Fix input/assertions/checks before testing, stop passed scenarios and reopen only for a relevant change or fresh failure; do not add unbounded follow-up gates. Current state has38 device/36 partial/29 pending, with65 unfinished acceptance records including shared scenarios. Reuse identical-input toolchains/packages and rerun current documentation gates; no further device test or production change. Completed captures are cleaned and142/Release/Home restored.

- Review the original EH139–142 loading trace and preserve its fault input. Close014 only: real resolver plans have3 cached GETs plus1 page-specific origin POST with separated gate/invocation/host timing. Explicit consumer-pacing stops explain the4.223/5.006s neighbor-body gaps; page139 waits6.278s for its first playable prefix. Warm Release and bounded Profile visits present without another required gesture, but do not close cold loading or DNS retirement. ZIC routes through NekoBox VPN DNS172.19.0.2; no attributable resolver error is available. Correct stale whole-chapter carrier/static-deadline wording and the false independent-native-clock interpretation of rhttp progress. Replace the mistouch assumption with user-confirmed automatic locking in the existing UI skill/rules. Fresh required2342/27 analyzers/Rust22/three-ABI Debug and JNI checks pass; reuse identical-input ordinary packages/native112. Restore Release/Home, delete completed exports, update bounded state to37 device/34 partial/32 pending and retain66 open criteria. Production code is unchanged.

- Extend ordinary Release acceptance to the current8 source rows: actual selected section switches and page1→2→1 pass, including Venera JM 單本 and temporarily enabled MangaDex/Junmeitu; restore both original disabled flags. Keep103 partial for untested popular/category/language pagination, and keep readonly filter sheets separate from applied-filter acceptance. All34 current browse requests complete; one cold Mihon JM cover reports a network connection reset without prior cache-hit evidence. Record the verified idle mistouch-protection retry, keep production unchanged, update existing bounded state/docs and delete completed host/device exports directly.

- Correct the known idle mistouch-protection test procedure: after the first ordinary tap leaves Home unchanged, wait1s, refresh XML and retry the same unique navigation target once. The current Release then opens the source page. Withdraw the earlier single-attempt input-limitation conclusion and update the existing Android UI skill, AGENTS and handoff; physical touch latency/final display remain unverified. Production and test data are unchanged; no new helper or capture is created.

- Record actual ordinary Release WNACG latest/popular and E-Hentai explore0/1 switches plus page1→2→1 for both sources. Keep103 partial for other sources/category variants. Eight real Reader local misses take6.594–27.177ms (median14.803ms); all eight origin bodies complete and page0 reaches first frame in3.447s. Mark008 partial, retain cold partial/storage-side absence and the original041 cleartext-origin case. Production is unchanged; reuse identical-input toolchain/package results and rerun current documentation/ownership gates. Delete the completed host/device trace and temporary helper directly; preserve original fault inputs.

- Restrict shared temporary-file cleanup to exact task-created paths and check actual UI plus runner Errors/Failures rather than exit code alone. A broad cleanup glob accidentally removed older temporary XML; its complete file list is unknown. No active consumer or current application/test/documentation reference was found, and current Home XML remains. Correct the existing Android UI skill and project rules without adding captures or a cleanup manifest.

- Fix the first source-switch frame ignoring an exact target browse cache before a UI visit snapshot exists; retire mismatched content when schema discovery changes the section/filter request. Both defects are reproduced before the fix; six regressions cover exact/mismatched cache, current/retired failures, round trips and UI-ordered default-section cache/miss. Ordinary Release completes three real Mihon/Venera offline round trips with six network failures: target cache first, target errors after cache invalidation, no old-source cards, then online recovery. Full2342/27 analyzers/Rust22/three-ABI Debug, JNI and fresh ordinary Profile/minified Release packages pass; native112 reuses unchanged Kotlin/native inputs. Close078, delete its completed exports/helper and retain current conclusions; physical input/performance and original19/20 remain open. Existing projection/generation/source/cache owners remain.

- Delete30 completed private test files (24,459,994 bytes) after current-reference and active-consumer checks. Keep the4 original reported .log traces,1 necessary source APK and32 open GC inputs. Accepted scopes remain closed after their raw output is removed; reuse current logs/XML and clean temporary helpers on exit. No bulk relocation or new cleanup manifest.

- Close045 with two executable Gateway fixtures: plain and controlled full-byte/Range callbacks share one source plan, preserve source headers and control, deliver bytes before EOF and leave metadata/artwork cache objects intact. Both raw full-byte bypass mutations fail the regression assertions. Use the application transport-injection boundary without sockets or fixed waits; production code and the original stability gate remain unchanged. Fresh required2336 tests/27 analyzers/Rust22/three-ABI Debug and JNI checks pass; native112 and six ordinary packages reuse unchanged production inputs. Keep .log at5 necessary originals, overwrite the existing validation log and clean all temporary probes on exit. Clarify that missing historical captures do not reopen accepted scope; original loading and performance remain open.

- Close058/059 on actual ordinary Profile details: JM cover,13 avatars and2 comment emoji each mount one Image and reuse role-matched cache bytes; expanded E-Hentai has371 preview records and9 mounted crop/size listeners, each occurring once with no extra Image. Cover/avatar/preview cache keys remain separate. Correct the test route to long-press single-chapter shelf cards for details; an ordinary tap enters Reader. Delete completed temporary screenshots/probes and two unreferenced Flutter crash logs directly, keep .log at5 necessary inputs, and add no audit or evidence file. Fresh required2334 tests/27 analyzers/Rust22/three-ABI Debug and JNI checks pass; native112 and six ordinary packages reuse the same production-input validation. Restore ordinary Release67e4e4d0/PID14195 to Home. Physical input, original loading and performance remain open.

- Fix manual Mihon migration rejecting native manga URLs, and fix its comparison overwriting the original alias catalog. Preserve full opaque/source fields and raw response IDs; cache complete manifests per raw request while sharing canonical invalidation, artwork and the runtime URL lock. Two failed-first regressions pass, including shared artwork and strict model/scope guards. New ordinary Profile and minified Release each twice return41 target chapters (exact1/unmatched0/extra40), then retain the original41-chapter detail with one chapter41 row and its page1 history; no migration is confirmed. Required2334 tests/27 analyzers/Rust22, native112 and all6 ordinary packages pass; native tests use the same Kotlin inputs, with temporary vendor SDK34/ASM9.9 compatibility under JDK25. Keep .log at5 necessary originals, delete completed private results and task scratch, and create no audit or capture.

- Close051 by reading the selected real Venera detail cover Future/provider: it reuses the canonical cache byte object and reaches first frame. Actual Mihon JM browse/details/Reader/history also reuse one62333-byte retained artwork-v2 record while description enriches0→39; mark062 partial and retain real mutable-alias variants. Add two bounded VM identity/owner checks to the existing Reader skill, with no production changes. Analyze the one temporary599-event trace (21 pages,7 first frames,0task failures), then delete host/device probes, screenshots and exports; keep .log at5 necessary originals. Fresh required2332 tests/27 analyzers/Rust22/three-ABI Debug and native packaging pass; ordinary packages/native110 reuse unchanged production inputs.

- Use the existing Android base test library to run a bounded legacy UiAutomator control; exact accessibility actions verify ordinary source/details/Reader/history routes while physical input remains unverified. Real Venera JM artwork keeps one canonical key/hash across browse, retained promotion and history, including a cold durable hit. Mark051 partial: the VM sample belongs to retained Home artwork, so details origin still needs its own observation. Restore ordinary Release Home and delete all temporary probes, exports and manifests; update existing state and testing skill without production changes or new audit files.

- Unify preflight input commands and CLI hints through the same explicit touchscreen/keyboard source helper; the existing regression fails before the repair and passes afterward. Recheck ordinary Home input with a system-menu comparison and matching-PID read-only Profile fields, without inferring a Reader/cache defect from failed injection or object metadata counts. Restore ordinary Release Home, remove forwards/temporary captures, and keep manual input, original loading and performance acceptance open in the existing bounded state. Required2332 tests/27 suites/analyzers/Rust22/three-ABI Debug and native packaging pass; three existing quarantined skips remain explicit.

- Delete completed test artifacts directly: remove3,547 obsolete files and reclaim12.7GB across the old temporary trace directory and private cache, then remove51 completed progress/exit and rejected-locator-candidate files (99.9MB) after reference and consumer checks. Preserve the4 original reported traces, original source APKs, current results and minimum open-issue captures; the32 current-production GC inputs remain byte-identical. Keep050/061/084 accepted and the locator candidate rejected after deleting their completed raw captures. Perfetto capture now streams its config, cleans remote/partial files on failure and replaces the current output only after a successful pull. Three mocked-command success/failure cases, the full required gate and all3 native packaging checks pass. Apply the same retention rules to private cache and existing test skills; no production Reader/cache/transport changes or new audit files. A temporary legacy UiAutomator input comparison cannot start because its platform test annotation is missing; clean both host/device files and retain input as unverified.

- Verify download completion through the existing Android Home entrypoint:58/58 checks pass, including7 new checks with a real isolated persistent chapter store and whole-comic queue. Existing bytes survive service reopen without a badge; pending commands show progress, chapter completion shows a white hollow check, queue completion a green solid check, and details entry clears both temporary marks. Close031 and remove its Plan item without production changes. Fresh required2332 tests/27 analyzers/Rust22/three-ABI Debug and native-release Profile/native packaging pass; ordinary Profile/Release and native110 reuse unchanged production inputs. Restore ordinary Releasefbca6e0b to Home and clean temporary data/exports/APKs. Back reaches the root Snackbar; ordinary touchscreen/Reader smoke remains unverified.

- Repair explicit source-card refresh of corrupt encoded covers: retain the current decode-failure observation until the user's source refresh, then pass one exact forceRefresh command through Home to the existing gateway/cache key. Healthy covers and another source's terminal Future remain intact. Retire the old Image State when its provider changes so an old decoder error cannot label the new response. Failing-first coverage, two stable regressions, artwork23/23 and Home51/51 native-release Profile acceptance pass; close083/108 without real-origin/durable corruption or original Reader-loading claims. Fresh required2332 Dart/Flutter tests,27 analyzers,Rust22 and all3 Debug/Profile/minified Release/native packaging pass; native110 is reused for unchanged Kotlin/native inputs. Restore ordinary Release fbca6e0b to Home; injected Home-card/navigation input did not change routes in ordinary Profile/Release, so its Reader slider smoke remains unverified without a product attribution. Update existing state/docs and promptly delete temporary exports/APKs/screenshots, without new audit files or bulk relocation.

- Extend the existing Android fixture to51 passing checks: actual Reader slider/normal-pop durable progress and history reuse one retained cover; exact artwork refresh, shelf comic deletion and settings cache clear respect their separate boundaries. Scope widget assertions to the active page and treat a removed cache directory as empty. Close034/035 in the existing state/Plan; production is unchanged. Required2330 tests/27 analyzers/Rust22/three-ABI Debug and native packaging pass; reuse ordinary Profile/Release for unchanged inputs. Restore ordinary Release Home and remove fixture data/exports/APK copies. Original19/20 loading, live-origin and remaining performance acceptance stay open.

- Repair retained-cover promotion when transient capacity trim has removed the durable file but memory still holds valid bytes. The byte store reports whether promotion found a payload; ResourceCacheManager restores only the current, unexpired response on the same key in background. Existing payloads keep metadata-only promotion; invalidate/clear/force-refresh revoke the old claim. Failing-first real-file coverage and six queued-lifetime cases pass. Existing Android Home/details fixture43/43 passes with24-cover pressure, metadata/catalog refresh, trim and source-free cold hits. Close033; keep034/035 Reader/history and allowed-invalidation criteria open. Fresh required2330 Dart/Flutter tests,27 analyzers,Rust22 and three-ABI Debug/Profile/minified Release/native packaging pass; native110 is reused only for unchanged Kotlin/native inputs. Ordinary Release restores Home and passes144章 page3→4→3 stationary slider/history smoke without a vertical gesture; original19/20 and performance remain open. Temporary data/exports are cleaned and no new audit file is created; remove one legacy trace wholly included byte for byte in a later retained original, leaving5 necessary .log files (~11MB) without bulk relocation.

- Close112 with the existing Android fixture's optional two-process mode:10 preparation checks plus6 cold-process checks pass after force-stop and a new PID. Persisted aliases show one shelf card before source activation; the unopened shelf starts no hidden cover requests, and cold durable cover hits make no source calls. Remove isolated data/device exports after completion, restore ordinary Release, and update current state without production changes or new audit files. Fresh required2322 Dart/Flutter tests,27 analyzers,Rust22 and three-ABI Debug pass.

- Extend the existing isolated Android fixture:30/30 checks pass, including independent fast/slow cover first frames with real durable writes held, reopened token-change cache hits without a source, and proven artifact fallback without exact-authority or unproven-page contamination. Close110/111; keep112 partial because owner reopen is not an actual process restart. Delete fixture scratch, device exports, obsolete private snapshots and fixture APKs after use; overwrite the existing result and restore ordinary Release. Fresh required2322 Dart/Flutter tests,27 analyzers,Rust22 and three-ABI Debug pass. Production is unchanged.

- Archive existing ADR/audit files and retain their checks and references. Move effective acceptance to one bounded IMPLEMENTATION_STATE.json projection with all112 IDs and independent remaining criteria, preserving full historical records in the archive. Pause new ADR/audit files and require parent-heading/production-owner checks before editing stable docs; detail layout stays under details, and Home lifecycle/migration ownership wording is corrected. Prune obsolete log files and completed temporary review trees; retain original fault inputs and require prompt cleanup rather than moving accumulated output elsewhere.

- Bound detail chapter layout to the outer viewport instead of a nested shrink-wrapped list. The 500-chapter regression fails on the old layout and preserves first/last opens and return progress after repair. On the same 144-chapter device catalog, exit build falls from80.291ms to19.314ms with CPU sampling and24.227ms without it; scrolling, sorting and page3 history pass. Required2322 Dart/Flutter tests,27 analyzers,Rust22 and three-ABI Debug/Profile/Release/native packaging pass. Close only061; checkpoint ownership, cache identities and original loading/display acceptance remain independent.

- Close084 with actual ordinary Profile progress WAL transactions: idle8s and active30s batching, with13 real page changes and no per-page commits. Warm199 frames have max build4.015ms and no new download. Keep061 open for an unattributed61.999ms exit build; CPU capture ends before pop. Restore ordinary Release, refresh the existing Home XML cache and update only current state; production is unchanged.

- Close065 on ordinary Mihon JM: first source detail saves144 chapters, repeated local routes open, actual Reader entry reaches page2 and immediately updates details/first Home history. Close038 against current process-cold durable hits and owned-byte tests; reuse only the hit component in063/066/112 and correct112's retired raw-key wording. Keep source failure/miss, alias, pressure and original loading/performance acceptance open. Unknown page-count metadata was a test interpretation error; production is unchanged.

- Close Plan109 against the existing current ordinary Release process-cold startup: new engine and visible Home precede durable capabilities, and nine durable-hit covers display before download queue/plugin readiness. Accept ADR0123, correct its source-availability retry/queue-ready wording and mark ADR0124's superseded file/raw-key clauses. Keep mixed-latency cover110, source/alias and physical-display acceptance open; production is unchanged and no audit file is added.

- Verify ordinary Reader route progress on the current Release: chapters20/21 retain separate pages5/75 and reentry restores5; another existing Venera history advances to page2, moves to first on the initial Home return and restores2. Close only Plan050 and reuse its product result in061/084; checkpoint frame cost, SQLite transaction cadence and original loading/performance remain open. Update existing state and Plan only; production is unchanged.

- Give all112 requirements an explicit current contract and keep original Plan wording historical. Reuse accepted Venera gate/HTTP results for014/016/021 while retaining real Reader timing and DNS acceptance; correct stale native-HTTP, non-media replay and ingress wording. Replace three copied allocation/installation records with references to the completed attribution and rejected fused-decoder candidate. Extend the existing documentation gate to reject missing current contracts, stale counts, hidden remaining acceptance and reopening that rejected candidate. Production and device state are unchanged.

- Consolidate all112 current requirement states in the existing governance audit: `status` is effective acceptance and `historical_status` records the original assertion. Retain scoped verification for042/088/090/096/107 and mark the dev.312 ARR task superseded; production still prohibits automatic activation. Merge46 redundant new audit files and replace copied child audits, installation snapshots, hash inventories and profiler logs with causes, boundaries, verification summaries and remaining work. Keep ADR evidence paths and report missing historical inputs separately from product defects. Production, identity, settings, data and APKs are unchanged; original loading/performance, true source generation, real notifications/migration and browser/DNS acceptance remain open. Correct the stale ARR documentation guard and retain existing device fixtures.

- Verify actual ordinary slider download on the same comic's existing chapter21 without forced reload or cache deletion. Three stationary gestures select pages74/115/71 and show target content at1s/6s/15s; the third revisits the first window rather than claiming the identical page. The first two lower-viewport neighbors are incomplete at1s and fill by6s without extra input. Seal all3287 new events inside two saturated exports:18 origins return200,18 artifacts seal and zero tasks fail. Page115 starts at current priority1000 and reaches its independently associated first frame in882796µs; observed transport/read slots remain at most5. Preserve all125 complete chapter payloads/URIs/revisions/import times and all67 read states; only chapter21 progress moves from index0 to70 with its timestamp and export time. Synchronize four state JSONs and current status/handoff while freezing536 historical audits,112 complete records, Plan and unchanged643 inputs/tests/APKs. Retain the prior2321/27/Rust22/Android110/six-APK gate. Original19/20 intermittent loading, active-scroll visuals, GC/input/final display, source generation and full browser lifecycle remain open; production is unchanged.

- Revalidate cached19/20 slider and chapter boundaries on the unchanged ordinary Release1b040401/PID8239. Six stationary steps and two independent entries with separately saved middle progress show actual content at1s/6s without follow-up input: top-down enters19 at its tail and bottom-up enters20 at its head, overriding historical middle pages. Seal the5844-event export and all4477 new events inside the second10000-event saturated export; their173 source reads are completed artifact-cache presentation-file leases, with zero download or task failure. Preserve all125 complete chapter payloads, URIs, revisions and import times; only tested19/20 progress timestamps,19 read-state timestamp and export time change. Synchronize four state JSONs and current status/handoff while freezing535 historical audits,112 complete requirements, Plan text,643 source inputs and tests; retain the existing2321/27/Rust22/Android110/six-APK validation. Original download-then-loading, stutter, GC/input latency, final display, source-generation and browser lifecycle acceptance remain open; no production repair is justified by this cached sample.

- Preserve native response Cookie identity and scope in the existing adapter (ADR0406 Accepted). A real installed WNACG1.6 source client failed five of nine controlled HTTP assertions before repair: path, Secure, expiry and same-name path identity were flattened. Retain complete Cookies, require expiry plus URL match and limit delayed-mirror suppression to the applicable domain/path. A new check catches the intermediate over-broad same-name mask before release; final15 actual-OkHttp checks and real-source9 pass. Preserve legacy browser handoff assertions with real OkHttp instead of stale stubs. Fresh2321 Dart/Flutter tests,27 analyzers, Rust22, Android110 and six ordinary APKs pass; all native/Dart libraries and public ABI remain exact, with intentional CookieJar Dex/common-asset changes sealed by generated checksums. Release1b040401/PID8239/Home revalidates title grouping, normal JM WebView and cold tag query/80-item response. Two direct exports retain102→116 events with no task failure/download; post-backup export succeeds without background/resume but does not attribute the earlier input anomaly. Synchronize four state JSONs while preserving534 historical audits,112 full records, Plan text and125 full chapter payloads/67 read states. Browser attributes, overlapping unknown mirror identities, real mirror-only root/private conditions, original19/20 loading, performance, source generation and full Cloudflare remain open.

- Match the Venera reference UTF-8 text boundary (ADR0405 Accepted). Java retained the initial BOM, causing JM JSON.parse failures displayed as connection errors. HTTP text and Convert.decodeUtf8 now consume exactly one initial mark; interior marks, binary bodies, GBK, identity/cache/trust and retry owners retain their existing contracts. Two valid assertions fail before repair; native110, fresh2321 Dart/Flutter tests,27 analyzers, Rust22 and six ordinary APKs pass. Same title query fails on old a2b2aa39 and returns the JM comic on Release739eeccb/PID27295; title groups, WebView and cold tag query/80-item response hold. Preserve533 historical audits,112/Plan and125 complete chapter payloads/67 read states. The102-event trace and two subsequent120-event exports contain no task failure/download. Independent ADB button nonresponse after backup returns recovers after background/resume, with its cause left open. This scope does not open Reader or close original19/20 loading, performance, real source generation or full Cloudflare acceptance.

- Consume an already issued metadata-tag query when the source page first mounts (ADR0404 Accepted). The previous warm-route test correctly covered revision updates but missed cold first entry, where initState ignored requestedQuery and sent empty-query Latest. Add one failing-first request-contract regression and seed only the existing query/controller before the original load; five production lines, no new route/owner/retry/cache policy. All60 focused and fresh2321/Rust22/27-analyzer checks pass; six ordinary APKs preserve every native library and Dex against0403, allowing exact native108 reuse. Releasea2b2aa39/PID24504/Home admits the actual Chinese tag as the first queryLength2/offset0 request with no preceding empty browse;85 exported events have zero download/task failure, without claiming an upstream response or search results. Synchronize four states, preserve532 prior audits/112/Plan and125 full chapter/URI/revision/progress records,67 read states and other backup domains except export time. Current Venera search API cause, original19/20 loading, real source generation and display/performance remain open.

- Preserve Mihon network classification when concrete transport exceptions wrap Android non-IO causes (ADR0403 Accepted). The production-extracted decision fails before repair; actual Roumanwu ConnectException/ErrnoException refusal now returns network and closes the runtime. Keep parser IO/UnknownService as source, cancellation/verification precedence and existing retry/replay owners; change one of643 production inputs only. Fresh2320 Dart/Flutter tests,27 analyzers, Rust22, Android108 and six ordinary Profile/Release APKs pass; install Release08d95b26/PID19276/Home with OS unchanged. WebView opens the normal JM site and Mihon title-result/details/tag route holds, but fresh Venera search cannot connect; preserve the partial smoke, its actual UI error and103-event trace without inferring API cause or counting diagnostic retryScheduled stages as transport retries. Retain superseded static-guard and private collector failures separately. Synchronize four state JSONs, freeze531 prior audits/112 fields/Plan and preserve125 complete chapters/URI/revision/progress,67 read states and every other backup domain except export time. Real source generation, original19/20 loading and CPU/GPU/display/performance remain open.

- Verify two real UploadLane output-preparation cancellation drains in a separate Android package, with the original uploader and native initialize Futures pending at route exit. Cursor/source/frame survive until the original return, late native candidates dispose and no old Reader presents; the123-event trace has zero task failures and original composition shutdown completes. Exact warm reentry occurs after the old preparation finishes and presents frame0 with zero additional reads, so active preparation overlap remains explicitly unverified. Preserve the first missed-window collector result, then record typed exit/final lifetimes and completed_partial instead of aborting drain or adding fake latency. Native blit/presentation and GPU/fence are separate boundaries. No production or repository test changes; reuse the exact2320/Rust22/27analyzer/native108/six-APK baseline. Freeze643 inputs,528 prior audits,112/Plan snapshots and previous scopes; synchronize four JSONs, preserve125 full chapters/67 read states and all other user data, and verify ordinary Release4bd8351d/PID12024/Home with unchanged OS.

- Verify active native decode retirement with an independent Android package and the unchanged production Reader/Pipeline/native bridge. Two actual route exits fall inside Rust fragment decoding (244.6–282.3ms); original TaskControl cancellation preserves cursor/source until the original Future returns, discards late frames and allows exact-session reentry before completion. The new cursor presents frame0 with zero extra body reads, all native resources drain, and634 trace events contain no task failures. Preserve the preliminary oracle and fixture errors separately; use a conservative single inner phase rather than a pending Future or outer Stopwatch as execution proof. Add a reusable device entry/runner and12 offline negative controls. Fresh2320 Dart/Flutter tests,27 analyzers and Rust22 pass; native108 and six ordinary APKs reuse unchanged643 production inputs. Keep527 old audits, frozen112/Plan and all prior scopes. Four state JSONs share scoped evidence; ordinary Release4bd8351d/PID12024/Home and125 complete chapter payloads/67 read states remain exact. Active upload, actual source revision/carrier, original loading and final display remain open.

- Verify real source provenance without changing production or the user's installed extensions. A read-only profile matches the installed Roumanwu1.6.21 APK SHA to chapter19's existing v3 revision. Retrieve official1.6.22 from its original release and match the published digest, Android version/package and signing certificate. A separate application ID runs both actual loadChapterControlled calls in independent native processes; both default-site catalog calls return network timeouts before any new manifest, Reader or media work. Preserve these failures and keep Plan097 real generation retirement open. Remove both test installations, restore ordinary Release4bd8351d/PID12024/Home and preserve125 complete chapter payloads,67 read states and all other backup domains except export time. Synchronize four state JSONs while freezing643 production inputs,526 historical audits, original112/Plan snapshots and prior scopes. Do not infer the original intermittent loading cause or change cache/DNS policies from this probe.

- Verify used native textures across three static and three animated Reader entries in an isolated Android Profile fixture, using the unchanged production Pipeline/Reader/texture bridge. Four warm entries retain the exact session with zero decode/upload sessions; all six used IDs are new, with78 native present replies, six release replies14–17ms after route exit, six real old-output rejections and no late present. Eight offline negative controls reject false evidence. The1595-event trace has zero task failures; five bounded decode-prefix growth waits are not provider retries. Restore ordinary Release4bd8351d/PID16169/Home and preserve all125 full chapter payloads,67 read states and every other backup domain exactly. Correct superseded Spec clauses for one retained session/Decode state and mandatory main-thread MethodChannel results; current two-key TTL/media retirement and platform scheduling behavior remain unchanged. Close only current Plan096 evidence while freezing original112,525 historical audits and all prior scopes. Source revision, active-task retirement, original loading and final-display acceptance remain open; release replies do not timestamp physical GPU retirement.

- Reconcile Reader retirement acceptance with the current two-minute TTL and two idle exact keys; the active Plan's second-chapter eviction wording was obsolete. SHA-bound ordinary Release4bd8351d/PID11582 records four TTL retirements at120.002–120.004s and actual20→19→21 entries: no retirement on the first two releases, only the oldest Reader retires957us after the third release, after20.164s retained. Reader-local media/claims retire while composition-owned physical transfers remain valid. The913-event new interval has20 artifact-cache reads and zero download/failure; all125 full chapter payloads and66 existing read states remain exact. Only three tested progress timestamps change and the actual details-row entry adds the expected default-unread state for21; all other backup domains remain exact. Preserve chapter-selector and overly strict read-state comparator errors separately; neither is a production regression. Synchronize current Plan097 evidence and four parent JSONs while freezing original112,524 historical audits and all previous scopes. Real source-revision/carrier changes, used native textures, active-task retirement, original loading and physical-display performance remain open; production is unchanged.

- Preserve released-slider and interior-entry centers across idle viewport, DPR and stitch changes through the existing layout correction. Corrected Android slider seeding reproduces86→85 on rotation; eight independent first-layout regressions fail before repair. DPR recreates ScrollPosition and skips its first physics correction, so a geometry-only adapter consumes the same pending target against the real incoming range. Eleven new stable cases,105 focused cases,2320 Dart/Flutter tests,27 analyzers, Rust22, Android108 and six ordinary Profile/Release APKs pass; non-app native libraries and Dex remain exact. Ordinary Release4bd8351d/PID11582 verifies28 geometry steps,16 actual OS changes, real tails with insets, stitch and28 stationary pixel negative controls. Cached19/20 smoke verifies six steps with114 cache reads and zero download/failure; all125 full chapter payloads/URIs/revisions remain exact, only actual19/20/21 progress timestamps change. Synchronize four state JSONs and Plan100 current evidence while preserving its original partial status, frozen112 and523 historical audits. Original intermittent loading, active-scroll visual continuity and GC/input/final-display acceptance remain open (ADR0402 Accepted).

- Bound oversized details preview rows by the existing page-height budget while retaining full-width equal-area tiles, contain painting, source order/count rules, shared folded/expanded geometry and sparse2.4. The original800×400 widget fails at1777.78 high and now renders332 high. Five stable regressions plus existing source-browser cases pass;14 actual Android controlled-window cases and28 marker-background negative controls verify layout and full PNG ends. Preserve the initial permissive pixel oracle as test-only evidence. Fresh2309 Dart/Flutter tests,27 analyzers, Rust22, Android108 and six ordinary Profile/Release APKs pass with unchanged non-app native libraries and Dex. Ordinary Release d4efdfbd/PID11106/Home revalidates six stationary cached19/20 slider/head/tail steps with124 cache reads and zero download/failure. All125 full chapter payloads/URIs/revisions remain exact, with only actual19/20 progress timestamps changing. Synchronize four state JSONs and close only Plan107; preserve frozen112,522 historical audits and0399/0400 scopes. Original intermittent loading, actual OS rotation/DPR and total GC/input/final display remain open (ADR0401 Accepted).

- Move only isolated Venera output encoding to the native host's existing executor after a two-prewarmed-worker Android regression proves that shared JavaBridge callbacks block. Preserve canonical1/isolated2, PNG/file output, physical encode/JS cleanup capacity, original close drain and late body discard. Callback6, real Binder11, fresh2304/Rust22/native108/27 analyzers and six ordinary APKs pass. Normal Release JM17 has8 successful origins with runtime plans at most60.489ms; JavaBridge CPU is571ms versus earlierJM18's4060ms under the same system-trace configuration. Different chapters do not prove throughput or totalCPU/GC improvement. Cached19/20 six stationary slider/head/tail steps have104 cache reads and zero new download/failure;125 complete chapter payloads/URIs/revisions/importedAt remain identical with only actual19/20 progress timestamps changing. Preserve original122 entries and only add normal JM19/18/17 chapters/readStates. Synchronize four state JSONs, close only known JM Plan088 attribution and accept ADR0400. System-DNS, original intermittent loading, overallGC/input latency and final display remain open.

- Separate JM Venera browser links from its JS update URL and accepted canonical identity; calibrate the browser-only album address to the same18comic.ink site used successfully by Mihon. Details titles open an independent search route grouped by enabled searchable source, with independent completion/errors and explicit retry; tags keep the original source destination even from nested results. Reuse the existing external-source lifecycle and projection notifications to add deferred cold sources without restarting completed groups or pagination. Preserve shared catalog/artwork/runtime owners, request coordinates and cache authority. Adapter59, six route/lifecycle regressions and required2304/Rust22/27 suites/analyzers pass; reuse native108 against unchanged inputs and identical native/Dex packaging. All six ordinary Profile/Release APKs match643 inputs; Release0f22bdc5/PID27221 passes true cold six-source grouping, original-result return, nested details/tag routing and normal JM-site opening. Six stationary cached19/20 slider/head/tail steps have5927 trace events,118 artifact-cache reads and zero download/failure. All122 complete chapter payloads/URIs/revisions/importedAt and all other backup domains remain identical; only actual19/20 progress timestamps and export time change. Preserve rejected.vip/static-roster evidence and separate test-harness defects. Synchronize four state JSONs and accept ADR0399; original intermittent loading, fixed-position stutter, overallGC/input latency and final display remain open.

- Verify six independent Android Venera page request-plan priority cases through real generated locators, NetLane controls, the original canonical gate, Service/Binder and the source WebView. Waiter780/900 jitter and ordinary active820/600 demotion cause no cancellation; current promotion, old-current demotion with a current waiter and existing previous pressure join old invocations in34.209/22.432/17.697 ms. Fourteen actual invocations include12 source-hook HTTP markers; nine successful plans expose gate/runtime/hook/network diagnostics, live priority determines transfer order and a cancelled gate waiter never enters the WebView. Canonical concurrency stays1; production642 inputs and native libraries remain unchanged. Preserve one fixture-only redundant-type-check lint correction. Fresh2297 tests,27 analyzers, Rust22 and three fixture ABIs pass; reuse native108 and six ordinary APKs against unchanged production inputs. Restore Releasef766349c/PID27886/Home and preserve all120 complete chapter/URI/revision/progress records and other backup domains except export time. Synchronize four state JSONs, retain frozen112 fields, and narrow Plan088 to actual-origin second-scale attribution. HTTP/DNS blocking-read cancellation, original loading and final display/performance remain open.

- Verify six Android Venera delay cases through the actual source adapter, NetLane control, Service/Binder and original single WebView invocation gate without changing production. Normal180/140/50 ms timers and negative-duration normalization pass; cancellation rejects two long timers and joins physical exit in21.874 ms while a foreign requestId timer completes normally after1801.5 ms. A subsequent invocation remains usable and canonical concurrency stays1. Preserve three fixture-only schema/literal/lint failures separately from product defects. All120 complete chapter/page/URI/revision/progress records and other backup domains remain exact except export time. Fresh2297 Dart/Flutter tests,27 analyzers, Rust22 and three fixture ABIs pass; Android108 and six ordinary APKs reuse the same642 production inputs. Restore Releasef766349c/PID25230/Home, synchronize four state JSONs and remove only the proved delay criterion from the active Plan. Frozen112 fields remain unchanged; HTTP/DNS blocking-read cancellation, priority preemption, original loading and final display/performance remain open.

- Reject fused UTF8/JSON decoding inside the original Mihon replay-coordinate predicate after actual Android Profile evidence:76,312 semantic comparisons match, including32,118 real persisted locators and malformed/Unicode/type boundaries, but the same288 checks still allocate288 Uint8List plus2304 GrowableList objects. Restore original production642 inputs and ordinary Releasef766349c/PID6016/Home; keep only two stable encoding/type contract tests. Candidate Profile/Release traces have74/99 cache reads with zero download/failure, and six stationary slider/head/tail steps pass before retirement. Restore profiler flags/class tracing and task-owned ADB forward. All120 complete chapter/page/URI/revision payloads and other backup domains stay exact; only actual19/20/21 reading progress and export time change. Fresh restored-source2297 tests,27 analyzers, Rust22 and Android108 pass; six candidate ordinary APKs are preserved as rejected evidence, and original six-APK proofs are reused against byte-identical restored inputs. Preserve three evidence-runner errors separately from product defects. Synchronize four state JSONs and frozen112 fields; original intermittent loading, fixed-position stutter, total allocation/GC, input latency and final display remain open.

- Attribute remaining Reader allocation/CPU on the current ordinary Profile without changing production642 inputs: four real cached-entry/chapter-boundary/selected-allocation/slider-scroll ROIs and4328 one-click-exported events show75 cache reads with zero download/failure. The existing Mihon replay-coordinate predicate produces2592 selected allocations across288 locator checks; no-allocation-tracing CPU samples match that path20 times at entry,22 at chapter boundaries and zero during slider/scroll. Separate these from Flutter layout/semantics work; one17.114ms Profile UI span and its aligned CPU/GC evidence do not establish the original fixed-position stutter or final display. Preserve120 complete chapter/page/URI/revision payloads and every non-reader domain; only actual20/21 progress and export time change. Restore flags, class tracing, task-owned ADB forward and Releasef766349c/PID28808/Home. Keep prior accepted scopes and frozen112 unchanged; validate any fused decoding candidate inside the original pure compatibility predicate before changing behavior.

- Verify six independent Pipeline cases using the actual installed WNACG1.6 APK/client and production Android runtime, redirected GET, sealed-file delivery, native static/animated output, zero-request cold READY and physical route cancellation. Eight HTTP requests yield four native first frames and59 presentations; source provider retries/task failures remain zero. Both cancellation TCP peers close in32–35ms. Preserve the initial fixture-only APK copy target failure and final-validator PID string/integer mismatch; repair only test staging and its assertion, keeping production642 inputs unchanged. All120 complete chapter/URI/revision/progress records and other backup domains remain exact except export time; original extension APK remains byte-identical. Fresh2295 Dart/Flutter tests, Rust22,27 analyzers and three fixture ABIs pass; Android108 and six ordinary APKs reuse identical production inputs. Restore ordinary Releasef766349c/PID26198/Home, synchronize four state JSONs and narrow Plan049 only for this selected client/GET boundary. Real origins, other clients/ABIs, CookieJar/POST, partial/live streams and original loading/display/performance remain open.

- Verify six independent Android native WebP source Pipeline cases: canonical onResponse preserves static/animated encoded bytes through sealed-file delivery, durable READY and original native texture presentation; new cold owners make zero source requests; two input cancellations close the TCP peer within26ms without READY/frame pollution. Four HTTP requests produce four first frames and58 actual presentations with zero provider retry/task failure. Retain two test defects separately: exec-in staging reported success without a file, and the oracle confused bounded decode-prefix growth with provider retries. Production642 inputs stay unchanged. Fresh2295 Dart/Flutter tests, Rust22 and27 suites/analyzers plus three fixture ABIs pass; native108 and six ordinary APKs reuse identical production inputs. Restore ordinary Releasef766349c/PID16250/Home; all120 complete chapters/URI/revision/progress and other backup domains remain exact except export time. Synchronize four state JSONs and narrow only selected NativeWebP acceptance in Plan049; real origins/Mihon, partial streaming, input allocation, original loading and final display/performance remain open.

- Verify eight independent Android Venera host/source-client Cookie and redirect Pipeline cases without changing production: stateless streaming, Set-Cookie fallback, CookieManager continuity, same/cross-origin redirects, POST303/307 and held source-body cancellation. Actual20 HTTP requests produce7 exact1,439,246-byte PNG READY/frames with0 retry/failure; cancelled work and its TCP peer exit within63ms. Expire/audit only current and interrupted-run fixture cookies. Preserve two intermediate test-contract/cleanup errors and never repair production to satisfy them. Fresh2295/Rust22/27 analyzers and three fixture ABIs pass; native108 and six ordinary APKs are reused against identical642 production inputs. Restore Releasef766349c/PID32395/Home; all120 complete chapter/URI/revision/progress records and remaining user backup domains stay exact except export time. Synchronize four state JSONs, preserve frozen112 and previous scopes, and align the active Plan's obsolete non-media forced-fallback wording with current typed semantic recovery. Real origins/Mihon/other HTTP variants, original loading and display/performance remain open.

- Join bounded source transport open and late response discard on scheduler cancellation before returning the original NetLane capacity. Preserve existing finite source/direct deadlines, retry budget and legacy watchdog behavior; repair only DownloadJob and ArtifactCacheTransport waiting boundaries (ADR0398 Accepted). Six regressions fail before and pass after; four actual cross-process resolver Network.post Pipeline cases pass, including active/backoff cancellation without late requests/READY/frames. Full2295/Rust22/native108 and27 analyzers pass; three ordinary Profile/Release and fixture ABIs retain unchanged native libraries. Releasef766349c/PID9779/Home passes six stationary cached chapter19/20 slider/edge steps with116 cache reads and zero download/failure. Fixture backups preserve120 complete chapters/URIs/progress and all remaining domains except export time; subsequent real Reader actions change only chapter19/20 progress/read state. Synchronize four state JSONs and remove only the proven runtime-network Plan criterion, preserving frozen112 fields and previous acceptance scopes. Original intermittent loading, other sources/clients, GC/input latency and final display remain open.

- Add an independent test-only deferred Reader source-failure/retry Pipeline fixture. Six controlled cases pass through actual source/Service/Binder/HTTP/rhttp and the original physical download owner: stable source errors terminate once, TCP EOF retries once to PNG READY/frame or exhausts after three attempts, and teardown during retry backoff joins without a late request/READY/frame. Preserve bounded source semantic re-resolution inside the same attempt. Classify and retain three intermediate fixture oracle/observer failures; do not change production to satisfy them. Full2289/Rust22 and27 analyzers pass; three fixture ABIs retain every non-app native library from the production Profile. Restore ordinary Release7ae75ff0/PID28049/Home. All120 complete chapter/URI/progress records and all other backup domains are exact except creation time. Synchronize four state JSONs and narrow active Plan042 to the untested runtime-resolver network boundary, preserving original112 fields/snapshot and previous scopes. Real sources/clients, canonical/live input, original19/20 loading and final display remain open.

- Add an independent test-only source Pipeline/persistent-cache fixture. Six selected canonical/isolated cases pass through actual HTTP/rhttp/source/Service/Binder/file, original DownloadSession and durable1,606,837-byte READY into PNG Reader presentation. Cold entries use new store/cache/transfer/raster owners and make zero source requests; route cancellation joins TCP/physical exit without READY/frame pollution. Four actual screenshots show content. Restore ordinary Release7ae75ff0/PID28586/Home; all120 chapters, URI/progress and other exported fields are exact except creation time. Production642 inputs remain unchanged; original112 and earlier9/9/11 scopes stay independent. Remaining variants/nativeWebP/real sources, allocation/live streaming, original19/20 loading and final display stay open.

- Count UTF-8 string keys/values without materializing byte arrays in the existing external runtime response budget. Preserve exact limits, replacement semantics, depth/type checks and all ownership/cache policies. Nine encoder-oracle boundary tests pass before/after; new Profile removes2692 distinct `_wireSize` Uint8List allocations while real runtime samples remain. Total allocations do not decrease, so overall GC/performance and the original19/20 loading cause stay open. Full2289/Rust22/native108,27 suites/analyzers and three ordinary Profile/Release ABIs pass. Release7ae75ff0 passes six stationary slider/edge steps, three saved-history overrides and204 cache reads without download/failure; one intentional reload and cold11-cache-read reentry pass. All120 complete chapters/URIs stay exact. Synchronize four state JSONs and current installation PID26183/Home; preserve original112 identities/statuses/snapshot (ADR0397 Accepted).

- Remove the already-verified same-session Reader reentry check from the active Plan after reconciling eleven SHA-bound current-production reentries at14.01–94.40 seconds. Each retains41–51 download sessions with zero decoded/upload sessions; the deduplicated trace has no download/failure. Preserve the SPEC contract that Reader-local media retires on exit and may be rebuilt on reentry. Keep texture/TTL/revision/LRU criteria open and original112 identity/status/snapshot unchanged; seven completed active Plan checks are now removed with evidence. No production change.

- Add a test-only actual HTTP/source/Service/Binder/file/ByteResponse fixture. Nine selected canonical/isolated SourceResourceTransport cases pass with1,439,246-byte input,1,606,837-byte sealed output, bounded64KiB reads, matching Range/mismatched validator/discard and real TCP input cancellation. Synthetic Cookie/POST and source UA survive actual HTTP. Full2280/Rust22 and27 analyzers pass; production642 inputs stay unchanged. Restore ordinary Release7ad3a60d/PID2327/Home; all120 complete chapters, URI/progress and other non-creation backup fields remain exact. Synchronize four state JSONs and scoped Plan049 evidence. Real-source CookieJar/client/origin, full Pipeline/teardown, whole-input/canonical allocation, original loading and final display remain open.

- Remove six already-verified toolchain/device tasks from the active Plan after checking current2280/Rust22 gates, frozen642 production inputs, six ordinary APK bindings and the current minified exception class definition. Preserve original112 identities/requirements/statuses and all incomplete product/source/performance criteria; no production behavior changes. Record the completed-task projection in the four shared governance JSONs.

- Add a test-only real Dart MethodChannel/Binder/file-body consumer fixture without changing production. Nine cases and a controlled replay verify bounded1,095,184/4,015,786-byte reads, six cancellations/closes while real RAF Futures are pending, and source death/reactivation after claim. Physical reads exit before single RAF close/native release; retired reads deliver no bytes. Full2280/Rust22 and27 analyzers pass. Restore ordinary Release7ad3a60d/PID16496/Home against642 frozen inputs; adjacent replay backups preserve all120 chapter/progress records and other exported data. Retain an earlier unattributed read-time change separately. Reconcile four shared JSON scopes and Plan049 evidence without changing the original112 statuses/snapshot; real HTTP/full Pipeline/teardown, input/canonical whole bytes, original loading and display remain open.

- Make public explicit artifact invalidation compare body authority without maintenance recency. The full gate exposes a surviving logical cache record after a read; a controlled touch interleaving fails before repair, while replaced-generation protection passes. Keep all other record comparisons and asynchronous touch scheduling intact; retain the original alias deletion test unchanged. Full2280/Rust22/Android108 and three-ABI packaging pass; normal Release explicit reload performs one intentional download and subsequent actual cold entry reuses11 cache pages without download/failure (ADR0396 Accepted).

- Preserve an interior Reader history entry center when short-page dimensions arrive after the initial layout acknowledgment. Reuse the existing absolute anchor and navigation revision; real content motion and new commands retain their retirement boundary, with ordinary top/tail and chapter-edge behavior intact. Two valid first-mount/replacement regressions fail at index2→3 before repair and pass afterward; all99 Reader tests pass. Full2280/Rust22/Android108 and three-ABI packaging pass. Three actual cold JM entries preserve the already-saved index3; six slider/edge steps and three independent-history boundary cases pass. Deduplicated same-process trace has226 cache reads/0 downloads/failures, and all120 complete chapter payloads remain exact (ADR0395 Accepted). Original intermittent19/20 loading and final display performance remain open.

- Add a repository Android Binder body fixture and reconcile eleven actual cross-process native lifetime cases plus one normal replay. Verify3.66/14.52MB byte/pixel equality, hash cancellation/close, source/producer loss, session close, host restart and the original65.063s RPC timeout. Production remains unchanged throughout that native phase; all8 exported data domains/120 chapters/progress stay exact. Restored cached Reader content exposes a separate short-page history drift, recorded for a separate fix. Full Dart consumer/HTTP/final-display scope remains open.

- Negotiate Venera transform-output sealed files independently of loadResource through the original body owner; isolated Bitmap encoding writes directly and canonical onResponse semantics stay intact. Required2276/Rust22,108 Android units and three-ABI Profile/minified Release pass. Native canonical/isolated output922147B matches old bytes/pixels and scoped lease/encoder cancellation checks pass. Ordinary Release08709052/642 inputs reads119 cached19/20 bodies with no downloads/failures, then a real JM reload transforms19492→243063B through the two-process sealed body path; route reentry reads10 caches with no downloads/failures and stationary1s/6s content. All120 complete chapters/URIs/importedAt and six other domains stay exact; only three normal progress records change. Input/canonical whole bytes, large cross-process cancellation/close/process-loss/RPC timeout, original loading and final-display performance remain open (ADR0394 Provisional).

- Let the original runtime body transaction accept a bounded native encoder OutputStream directly; share proof and atomic sealing with InputStream. Retire borrowed streams before publication, retain physical producer completion and reject caught write/limit failures. Required2259/Rust22,108 Android and three-ABI Profile/Release pass. Actual919758B Bitmap/legacy proof/lease/cancel checks pass on Profile; ordinary Release3d835b38 verifies six cached19/20 steps with122 cache reads, no download/failure and all120 complete chapters unchanged. Accept the primitive only; full Venera input/output integration and original loading/performance remain open (ADR0393 Accepted).

- Supplement runtime close evidence without changing production: the same APK probe fails the old Service engine and full worker close boundaries and passes current production engine/rhttp cancellation, original IPC fences and both actual WebView transform workers. Keep Android bind/process teardown, large cross-process replies, real-origin/RPC timeout, body carriers and original loading/display open. Clarify the completed device Mihon extension version/ABI scope in current status and handoff (ADR0392 remains Provisional).

- Join admitted native work before runtime close replies/resource cleanup; repeated close and late activation retire at the same boundary. Actual old APK fails four close cases; the current APK passes five native close fixtures plus prior normal/cancellation contracts. All2259 Dart/Flutter, Rust22, native103 and three Profile/Release ABIs pass. Ordinary Releasea71c7e1b shows108 cached19/20 reads with0 downloads/failures; all120 complete chapters stay exact. Service integration, full transform/body delivery and original loading/display acceptance remain open (ADR0392 Provisional).

- Keep the canonical Venera invocation permit and cancellation identity until both JavaScript finish and admitted native bridge calls exit. Stage original results, reject late body-token registration and retire only cancelled-request tokens. Current2259/Rust22/native97 and three Profile/Release ABIs pass. The same device probe fails the baseline bridge and passes the new bridge; ordinary Release4352e476 reopens Venera with a79ms cached current frame, five real origin reads and no task failure. All120 complete chapter objects remain exact, with one normal progress update. Venera body carriers, integrated real-origin cancellation/process loss and original loading/performance acceptance remain open.

- Add explicit Android system-trace phases around the original Mihon client execution, exact bulk-read overload, body seal and host claim. Keep the pure file owner Android-free and use the original stream with tracing disabled. Current2259/Rust22/native89 and all three Profile/Release ABIs pass. Release2fe9f04e/PID32750 matches640 inputs; final Profile reads dominate seal96–99%, page68 presents8.55s after mount without another gesture, then cold Release reads11 caches with no download and a174ms first frame. Earlier diagnostic snapshot cached19/20 slider/boundary smoke has116 cache reads and no download/failure; preserve its separate source/package provenance. All120 complete chapter objects/URIs/importedAt remain exact; three normal progress records and the required automatic20-head unread reset change. Extension metadata acceptance stays closed; original loading and final display remain open.

- Add negotiated Mihon source-owned sealed body delivery through the existing invocation/packet owners. Preserve the source client/interceptors, original locator and legacy validator; verify raw-body integrity off the UI thread and retire the consumer only after physical reads exit. Image/Range admission and durable authority stay with the existing source transport and download owners. Eight file-lifetime, fourteen packet/body and fifteen channel checks pass. Required2259/Rust22,89 Android units and three-ABI Profile/Release pass, with test-only JDK17/SDK34 for the legacy third-party suite. Ordinary Release6b15ca30/PID18523 matches640 production inputs: eleven real WNACG bodies total36491405B, cold page90 reentry has eleven cache reads and no download; nineteen–twenty-one chapter regression phases have257 cache reads and no download/failure. Six directional first/last crossings and three independently preserved interior-history overrides pass. All120 complete chapter objects remain identical; only four progress records, two read timestamps and the visited chapter21 marker acknowledgement change. Venera, live streaming, original19/20 intermittent loading and final-display acceptance remain open (ADR0390 Provisional).
- Mihon body领取绑定原process/session/request；先保护lease再做可取消校验，取消与关闭等待已接纳IO及清理退出后才结算。
- 修复body release尚未完成便移除登记，导致并发connection.close提前结束的竞态；阻塞release回归先失败，修复后15项channel及完整门禁通过。复用原登记与dispose Future，不新增队列/owner。未缓存WNACG90页首帧21.8s，其中source host-open21.4s；冷重入192.6ms。网络/client/写文件/claim成本尚未细分，不推断原加载或最终性能已修复。

- Verify a real103-page WNACG chapter through the ordinary minified source/details/Reader entry. Eight HTTP.cfd origin bodies total20288603 bytes through the source's custom-client runtime path, with no failure; page0 presents4.20s after mount and7.27s before the first control tap. Preserve all119 prior complete chapter/progress records and all other prior records; add only the actually read chapter/catalog/read state, without shelf admission. Keep old.ru, direct-host/protocol fallback, Cookie/POST and final performance criteria open. Complete the Plan's source-owned binary-body delivery evaluation: existing authenticated IPC packet files contain codec envelopes and still reassemble full bytes, so they cannot be passed as raw images. Record candidate body leases and mandatory ownership/lifetime/cancellation gates in the feasibility audit; at that earlier evaluation-only stage, no protocol or production change had been implemented.

- Persist source-declared predecessor→current history through the existing version relation owner, alongside current→successor discovery. The genuine missing-edge regression fails before repair; nine lifecycle checks preserve the original discovery time/media proof, reject foreign/self/empty identities and retain predecessors offline. Required2235/27 suites/3 existing skips/Rust22, three-ABI Profile/Release and native/Dex/manifest checks pass. Ordinary Release3e65ae94 verifies the correct WNACG device section v1.6.0/ABI1.6, readable download rows, five stationary sliders and four directional first/last-page crossings, overriding historical pages91/82. All119 complete chapters remain identical; only four progress and two read-state timestamps change. The saturated10000-event one-click trace retains four slider releases with target frames48.545–122.256ms later,178 cache reads and no download/failure; early source/first-slider records are absent. Exclude the probe's approximate-coordinate page80 assertion, preserve frame/final-display limits and leave the original19/20 cause open. E-Hentai's current adapter returns successors only, so real predecessor input and notice preconditions remain unverified; ADR0389 stays Provisional. Cache identity/trust, Reader and NetLane policies stay intact.

- Verify the shelf marker/dim surface on a real E-Hentai source card and keep independently returned native versions off shelf. All seven backup sections and119 complete chapters stay identical; the201-record one-click export adds90 UI-only events, with no failure/download. Its19 retryScheduled entries are three browse starts and16 cover starts. Reconcile Plan023 pending→partial and current installation evidence; the positive update action, original loading and final performance remain open. Production code is unchanged.

- Extend controlled migration acceptance to interruptions after real artifact binding, target progress and old-chapter deletion, before each callback finishes. Ten cases pass300 checks with five phase-boundary and three callback-internal force-stop/relaunches; durable binding is reused, target progress wins on replay and offline cleanup completes. Production files stay unchanged. Required2234/27 suites/3 existing skips/Rust22 passes; ordinary Release is restored and all7 user sections/119 complete chapters remain equal. Reverify WNACG v1.6.0/ABI1.6 in the device-extension section and readable download rows; exclude an update-prompt-obscured screenshot and replace it with visually checked evidence. Reconcile current installation and controlled callback scope in state JSON; original112 statuses/SHA, live-origin/main confirmation, loading and final-display limits remain unchanged.

- Reconcile migration comparison confidence with the original ADR0016/dev146 implementation: title+sequence correspondence is independently checked against target native identity and never replaces media proof. Production behavior stays unchanged. A minified Release entrypoint using isolated real SQLite/body files passes193 checks for same/cross-source state precedence, sequence-only exclusion, physical reuse/retention and five actual phase-boundary force-stop/relaunches. Fix its initial seed-before-session test setup and exclude the failed run. Required2234/27 suites/3 existing skips/Rust22 passes; ordinary Release is restored and all7 user backup sections, including119 complete chapters, remain exactly equal. WNACG system v1.6.0/ABI1.6 displays in the correct Mihon device section; the95-record UI-only export has0 task failures. Plan075 moves pending→partial; ordinary live-origin confirmation/alias UI, within-callback interruption, original loading and final display remain open.

- 详情正文准备先hydrate exact持久记录再判定revision/pageCount/locator；有效记录保留importedAt和进度，缺失/变化/旧locator仍由来源加载。实际Home回调2合法例先失败/5负例通过；42定向、2234/Rust22全门禁及三ABI通过。普通Release升级全部区段一致，实际Reader后119条完整chapter含importedAt/URI/revision严格不变；仅实际进度/已读变化。5静置slider/5跨章、正确Mihon设备v1.6.0/ABI1.6及下载管理再验通过。连续12169导出记录中285读均artifact-cache、0下载/0失败；101.623ms含100.469ms vsync overhead仍未归属。ADR0388 Accepted；原19/20故障、GC/最终显示性能开放。
- 同源版本准备先读取完整持久章节，再检查locator；保留旧locator刷新并重验取消。2227/Rust22/三ABI与普通Release严格119章升级、只读查看比较通过，5次静置slider/5次跨章复验通过。连续12417事件中285次读均命中artifact-cache，无下载开始或任务失败。ADR0387 Accepted；详情首次选20话的独立导入时间变化、原19/20加载与最终显示性能仍开放。

- Make the generic confirmed-version picker consume the existing source refresh and display readable normal Web addresses, with actions below full-width metadata. Stored relation discovery timestamps no longer masquerade as source dates; exact selection, cached failure fallback and owner work after close remain intact. Failing-first/owner/widget checks, required2224/27 suites/Rust22 and three-ABI Profile/Release pass. Ordinary Release verifies real source dates,551-page view off shelf/return to371-page original, unified comparison acknowledgement/close and correct WNACG device metadata. The108-event UI export has no failures and no Reader run. All119 page identities/URIs/revisions/progress and other backup sections stay unchanged; one target importedAt refresh exposes a separate compact version-preparation hydration observation. Confirmed migration, original loading and performance remain open (ADR0386 Accepted).

- Replace opaque migration comparison keys with source-owned normal Web addresses and meaningful comic/source/chapter-risk copy. Keep internal identity for cover seeds, comparison and exact transaction targets; acknowledgement remains required and no source lookup moves into the dialog. Required2221/27 suites/Rust22, three-ABI Profile/Release and ordinary real-gallery comparison pass; all6 APK runtime Dex files match the accepted source-document build. Correct Mihon device list still showsWNACG v1.6.0/ABI1.6; source main rows have no extension metadata. Preview/acknowledgement then close preserves all exported119-chapter/85-comic semantic records;101-event UI export has no failures. Align the existing cleanup-reopen test with asynchronous owner drain completion, preserving destination/debt/old-file checks and changing no production storage. Original Reader/loading/performance and remaining parent scope stay open.

- Separate Venera version HTML from image resource validation. Failing-first bootstrap/adapter/protocol checks prove gallery documents entered thumbnail hooks and the image-only native path, while stored version relations could mask failed fresh discovery. Explicit source-document intent uses the existing general binary token/session/requestId boundary; ordinary image validation, source recovery, cache identities and scheduling remain intact. Focused56, required2221/27 suites/Rust22 and three-ABI Profile/Release checks pass. Ordinary Release discovers the real2026-10-03 successor, opens its551-page detail and unified comparison preview; existing95 chapter payload/progress records and all other backup sections stay unchanged before Reader acceptance, with24 new version manifests carrying no progress. Three stationary sliders/four endpoints pass; retained10000-event tail has112 artifact-cache reads and0 downloads/task failures. Reconcile parent state and make Plan074 partial; first/later version notifications, original19/20 loading and final display remain open (ADR0385 Accepted).

- Verify Home update contracts on device without changing production code. A minified Release fixture passes 20 checks through production Home/details/SQLite owners for first admission, acknowledgement persistence, ordinary edits and later chapter/version notifications. User backup sections remain identical across fixture installation/restoration. The ordinary Release independently matches four Home update cases; a real 27-chapter metadata refresh changes no semantic record, and Reader155→144→155 changes only progress.updatedAt. Its 1014-event export has19 artifact-cache reads and0 downloads/task failures. Required gate2219/27 suites/Rust22 passes. State JSON now separates these verified scopes from live-origin version admission and final-display acceptance, which remain open (ADR0383 Provisional).

- Preserve the original complete key when sanitizing composite Trace payload identities. Two failing-first contracts expose provider regexes consuming the next length frame and corrupting diagnostic correlation; nested lists/map keys remain JSON-safe and idempotent. No runtime identity, URI, cache trust or scheduling changes. Focused17/full gate2219/27 suites/Rust22, three-ABI Profile/ordinary Release and JNI/FFI/AOT proofs pass. The installed9214-event one-click export independently matches127 long scopes and11 provider exact keys to original metadata; standalone manga length remains507. Five stationary sliders including real chapter21 downloads, four endpoints and correct Mihon/manual-title lists pass. Two stale full-validation links are reconciled to their already-passed audit. Original chapter19/20 loading, shelf-admission device and performance scopes remain open (ADR0384 Accepted).

- Correct the Mihon metadata requirement to the device-extension list. Remove the unnecessary installed-owner lookup and version/ABI subtitle from source toggles/settings; retain the existing separate package/metadata lines. A real signed WNACG system APK verifies v1.6.0 and ABI1.6. Earlier main-list checks remain historical evidence and do not satisfy this requirement; 2217 full tests/Rust22, three-ABI Profile/ordinary Release and the installed ordinary package verify both correct lists, manual titles/delete preview, three stationary sliders and four chapter endpoints. The6913-event export records143 cache reads and0 task failures; idle18.509/23.083ms build packets and the original loading report remain open.

- Extend safe download titles to manual orphan snapshots, old cold Home summaries and delete confirmation; use current logical metadata or generic labels while preserving exact identities, pins and mutation targets. Owner/UI failing-first, 2217 full tests/Rust22/three ABIs and ordinary Release list/delete preview pass; the reported chapter19/20 cache/loading issue remains open (ADR0382 Accepted).
- Persist first-shelf acknowledgement of the already known successor in ComicPreference, keeping ordinary edits and all family/reuse heads independent. Real Home callbacks, JSON/SQLite/backup, snapshot checks and 2217 full tests/Rust22/three ABIs pass; first-admission/later-signal device acceptance remains pending (ADR0383 Provisional).
- ADR0381 Accepted：Reader邻章查询只物化当前source的canonical comic family，memo限单次调用；保留代表/目录/entry/progress与首尾入口。2211全门禁/Rust22/三ABI、22匹配CPU帧与普通8430事件通过；独立GC/22.905ms build/最终显示/全来源开放。
- ADR0380：file presentation lease等待已启动的engine file/buffer/codec Future退出后关闭；修复cancelled prewarm/shared pending consumer的提前release，mounted退出仍异步，缓存key与Pipeline/Reader调度不变。
- Project Home snapshot durable fields before the existing encoding worker handoff. Allocation tracing found14,692 URI copies in one caller-thread spawn even though ordinary chapter entries persist only compact metadata. A valid failing-first isolates accidental owner-graph transfer; JSON/compression, full orphan metadata, schema4 and serialized durability remain on their existing boundaries. Device/performance revalidation remains open (ADR0379 Provisional).
- Merge canonical aliases at the ordinary/cached browse boundary while retaining source order, raw commands and native coordinates. Previous uses accepted visit coordinates and source return retains its page unless request partition changes.53 focused/2206 full tests,Rust22,three-ABI Profile/ordinary Release,JNI/FFI and18 isolated device checks pass. Ordinary Release8069 events verify native20 pages/source return, five cached stationary slider frames, four head/tail crossings and five Mihon version/ABI rows with0 task failures. Close the scoped contract;21.299ms return build/15.949ms reconcile, prior long frames/GC/final display/all-source/original112 remain open (ADR0378 Accepted).
- Preserve source-card Image State through raw alias metadata refresh using the existing canonical interaction key, while clicks keep the latest raw locator. Valid failing-first,50 focused/2203 full tests,Rust22,three-ABI Profile/minified Release,JNI/FFI and13 isolated device checks pass. Current ordinary Release8162 events verify five stationary slider first frames, four correct head/tail crossings and five Mihon version/ABI rows with0 task failures; page78 is an actual current origin download. Accept only the canonical subtree contract and keep the newly observed34.772ms chapter21-entry build, previous unsampled returns, GC/final display/all-source/original112 open (ADR0377 Accepted).
- Reconcile SWG-PLAN-022 with the existing raw rhttp stream and sole DownloadJob framing owner. Existing tiny1400-byte chunk behavior and required-toolchain guard pass; preserve response pacing/read permit/budget and make no production change or first-frame performance claim. Original112 requirements remain recorded.
- Deduplicate Home canonical alias checks, test source update evidence before shelf preferences, and reuse one read-only library aggregation within each synchronous Home build. Three valid failing-first checks, final29 focused/2203 full tests/Rust22, three-ABI Profile/ordinary Release and JNI/FFI pass. Matching Profile exit samples confirm reduced alias work; ordinary Release8050 events verify five stationary slider first frames, four correct head/tail crossings and five installed Mihon version/ABI rows with0 task failures. Accept the scoped query contract, keep GC/unsampled return frames/final display/all-source/original112 open, and synchronize all four current state records with the installed ordinary APK (ADR0376 Accepted).
- Preserve complete Mihon native browse pages and source-owned next request coordinates. A real 20-item source returned an empty second page because host offset20 still requested native page1; aligned coordinates also prevent truncating native pages larger than24 and preserve empty-more navigation. Kotlin/UI/adapter failing-first,2200 full tests,Rust22 and three native Release ABIs pass. Ordinary Release9767 events verify nonempty native page2, manager page preservation, five metadata rows, five stationary slider releases and six correct boundary transitions with0 task failures. Keep the35.255ms cached-return build and independent performance/all-source criteria open (ADR0375 Accepted).
- Preserve ordinary active browse across unrelated source-list changes, including pending loader, selected section and page. Reuse the current composition decorator only for the same source, response cache and producer binding generation; actual source/settings/cache replacement and aggregate exit retain their existing paths. Four focused checks and current2200 full tests pass; ordinary Release has five explicit browse requests with no manager-induced restart. Pending-loader coalescing is proved by the widget behavior test, and loaded-page preservation by device UI/trace (ADR0374 Accepted).
- Scope the existing Mihon installed-payload comparison to actual v3 runtime-transform chapter revisions. Ordinary Release Pixiv entry exposed the shared gate rejecting a valid fresh direct chapter; preserve legacy/mismatched carrier refresh and one Reader/download/version preparation gate. Failing-first, 39 focused/2192 full tests and native ordinary Release verify the original entry, three stationary slider releases, four correct boundary returns and five Mihon version/ABI rows; the complete6424-event export has no task failure. Reconcile current state while retaining independent performance/source conditions (ADR0373 Accepted).
- Match the three exact canonical Mihon default-client interceptors in the existing host replay capability check. An isolated source-classloader failing-first confirms ordinary requests incorrectly forced complete runtime body RPC; preserve unknown/source-owned capability and response recovery boundaries. Current/legacy raw-manga and80 complete-chapter behavior checks, required gate2190/Rust22/three ABIs and98 device assertions pass; two WNACG direct/fallback branches remain unverified because its installed payload has custom client logic. Restore the native ordinary Release and reconcile five Plan items as partial without changing the original112 requirements (ADR0372 Accepted).
- Review the remaining48.162ms callback sample as a drag-to-ballistic handoff. Fresh ordinary Release3014 events and diagnostic1782 events have no geometry velocity outlier; matched37.640/43.308ms diagnostic windows contain two short Flutter frames and mostly sleeping main-thread time. Preserve verified workers and scheduling; input latency, independent entry CPU and final presentation remain open. Restore the verified ordinary Release and close current documentation checks in the state JSON.
- Differentiate vertical motion from valid physical pixel samples evaluated in the same applied geometry. Port the baseline only by actual dimension correction; preserve input/callback clocks, backdated input coverage and unsampled motion. Directional failing-first fixtures isolate visible-ratio convergence manufacturing velocity or opposite direction; required gate2190/Rust22 and ordinary Release8183/5548 events verify13 active dimension updates without motion outliers (ADR0371 Accepted). The48.162ms callback handoff and final-display acceptance remain open.
- Preserve the prepared prefix geometry compensation when a new drag starts before its applying frame. Add intervening physical movement once across repeated layout passes; frame-timing diagnostics use a read-only preview. Failing-first fixtures isolate600px prefix jumps and100px lost motion from diagnostic reads;97 focused/full2190 and scoped ordinary Release verify the geometry handoff and slider/chapter contracts (ADR0370 Accepted).
- Use the existing Android OS document export operation for JSON library backups instead of file_selector's unsupported save-location API. Preserve the store-owned semantic snapshot, cancellation and shared platform single-pending lifecycle; report export errors independently of cache inspection. Save/cancel/retry and subsequent one-click Trace export pass on ordinary Release (ADR0368 Accepted).
- Project stored Mihon chapter metadata into its unique current catalog row after host ordinal/parent locator changes. Keep all source model fields, progress/manual read and original history identity; do not change page reuse or mutation targets. Use actual catalog scope across route aliases and display the stored count from compact Home metadata; preview navigation and placeholder page reuse retain their existing guards. Failing-first regressions and cold ordinary Release verify28 rows/1184 pages; retain the unproven missing-memo historical record (ADR0367 Accepted).
- Sample vertical velocity from the continuous applied-geometry viewport center while keeping semantic first/last navigation. Failing-first head/tail arrival and reversal tests isolate endpoint overrides from motion. Required gate2172/Rust22 and fresh ordinary Release7682 events/8 active dimensions verify no sampling outlier, slider first frame30.9ms after release and correct chapter boundaries (ADR0366 Accepted); cadence/final display remain independent.
- Preserve an already-prepared immutable chapter manifest across an equivalent SQLite upsert/readback. Compare complete persisted values, retain durable progress and actual changed metadata/page carriers, and preserve the existing no-op authority contract without repeated JSON encoding. Required gate2170/Rust22, matched next-entry Profile24.1→4.8ms and ordinary Release4104 events verify the scoped projection contract (ADR0365 Accepted).
- Preserve the content motion sampling interval across layout-only observations and raw pointer phase promotion; retire older coalesced sampling requests when direct drag input overtakes them. Sparse Release diagnostics and a failing-first test confirm duplicate pointer/ScrollUpdate sampling. Required gate2168/Rust22 and the fresh7719-event Release verify the scoped fix, slider and chapter boundaries (ADR0364 Accepted); final display/cadence acceptance remains open.
- Share one fresh adjacent-chapter query between previous/next availability checks in each synchronous Reader build. Entry CPU sampling identified duplicate canonical library aggregation; retain live command/preload queries, complete source-model matching and all scheduling boundaries.
- Reconcile partial Plan evidence and remove superseded blanket geometry/hidden-upload wording from active work. Preserve all112 original requirements and distinguish verified components from their remaining device criteria; later Pixiv success replaces the earlier failure as current evidence.
- Project logical chapter-order keys once per chapter in each sort call. Reader-entry CPU sampling exposed repeated Mihon opaque-ID decoding inside the comparator; retain ascending order, stable source ties and fresh per-call projection without a catalog cache (ADR0362).
- Prepare immutable chapter manifests within the existing persistent bulk-read worker before transferring records to Home. Startup CPU sampling found first page-URI parsing blocking the foreground authority build; keep the same record-local projection and close/join lifecycle, exact-read and backup boundaries (ADR0363).
- Pair vertical physical observations and cumulative prefix corrections with the immutable geometry captured by ListView. Fix frame-end ratio adoption publishing a transient page/velocity jump and consecutive header facts losing a prefix correction; add failing-first contracts (ADR0361).
- Preserve an idle real chapter tail through viewport, pixel-ratio and page-ratio changes using the existing atomic layout correction. Keep released slider center precedence, non-tail anchors and fitting chapters; initial previous-entry success alone no longer counts as stable-tail acceptance.
- Reuse the immutable manifest projection of each imported chapter record instead of reparsing unchanged page URIs across whole-library authority refreshes. Match a stale Mihon chapter to its unique current catalog position only when the complete source-owned model agrees; host ordinal/parent locator are excluded, runtime/download IDs and page reuse proof remain unchanged.
- Reject opaque resource payloads as standalone path/hash physical proof before per-page scanning. Fix coincident vertical chapter boundaries using pull direction and resolve explicit first/last entry after authoritative hydration/source refresh. Add locator and short/cold chapter regressions; keep device closure separate from toolchain checks.
- Show installed version/Mihon ABI in source/plugin management, preserve known metadata on activation failure, and reserve a separate device-row line for version/ABI so long package names cannot hide it.

- Preserve a failed source-card Future until explicit refresh instead of dropping it on error. Sliver disposal/reentry no longer restarts the same failed source request; add a failing-first regression covering remount and explicit recovery.
- Verify cache-first/unchanged refresh, content retention during pull refresh, repeated details and shelf add/remove on the second Profile device. Ten isolated first-device checks cover source/decode failure separation, offscreen completion and explicit source recovery without evicting other encoded covers; close only the supported Plan criteria.

- Restore Venera activation HTTP diagnostics for synthetic cancellation request IDs. Record opaque call IDs and client/header/body/cancellation stages through the existing resolver; eight cold Profile activations and all required-toolchain checks pass. Keep the earlier intermittent10s HTTP tail open.

- Verify Download Manager route-first ordering on the second Profile device: existing snapshots paint about46ms after opening, before the deferred2.94s inventory refresh. Two blocked-inspection/service-handoff regressions pass; close only Plan094 and preserve the remaining acceptance scope.

- Eliminate duplicate whole-library media authority rebuilds on chapter upsert. An identical full persisted payload preserves the existing scope; changed provider locators still publish even within the same revision. Preserve durable target persistence, canonical commit and final progress flush; add a failing-first owner regression.

- Await the Home route's existing source activation before materializing an uncached chapter, then re-read the live source; cached entry remains immediate and disposal fences late materialization. Add five lifecycle regressions for the cold-entry race exposed by the second device.
- Report zero vertical velocity during idle geometry/entry correction while retaining measured dragging and scrolling velocity. Cover provisional and warm entry geometry with failing-first regressions.
- Verify normal Profile cold slider releases to pages116/21 with dimensions arriving after release and no page drift or extra gesture; verify four chapter crossings enter exact first/last pages. Attribute the3.53–3.80s boundary delay to duplicate authority rebuilds; verify12–20ms cached crossings with explicit different-scope limits.

- Preserve a released slider's existing selected-page center when page dimensions arrive later. An empty pending map no longer retires the absolute navigation anchor; real content motion or a new command does. Keep input release, Pipeline execution and all scheduling budgets unchanged; cover both release/layout orderings and subsequent drag ownership.
- Display a page number and format for remote Reader assets instead of an opaque locator, preserve local filenames, and correct the About version to the current dev.328.
- Use the captured buffer's discarded-chunk counter for Perfetto integrity, independently of service-lifetime history. Correlate a fresh second-device Reader run with exact SurfaceView presentation cadence; missing content FrameTimeline and visual observation remain unverified.
- Keep one filter draft for each modal invocation. Route/keyboard rebuilds no longer discard pending Group checkbox or dropdown edits; add a failing-first metrics and combined-override regression and reverify the real MangaFire sheet on device.
- Initialize OkHttp 5 with the host application Context before the isolated plugin runtime engine and drivers start. Fix real minified Pixiv domain-resource failures without changing source account state, class-loader policy or network scheduling.
- Reconcile stale progress documentation and Plan criteria with Accepted ADR 0303: ordinary page checkpoints remain batched, normal pop awaits the final durable flush, and Home uses a targeted final-progress update. Preserve production behavior and update the obsolete documentation guard.
- Correct Venera `multiPartPage` collection pagination: call the source with a null page, slice by global offset, and stop at collection exhaustion. Keep native-page and cursor contracts, source objects and all Reader scheduling boundaries unchanged; add failing-first executable JS coverage.
- Correct the Perfetto analyzer to count NULL/zero SurfaceFlinger display tokens, reject trace integrity errors and require the Flutter SurfaceView content layer before drawing presentation conclusions. Execute its SQL and verdict against fixtures; missing content-layer coverage remains unverified.
- Verify stationary slider first frames (about 40–194ms), previous/next chapter boundary returns, and 2.401s animated same-session reentry on native Profile. Keep the full 112-item acceptance audit active; later trace rings are truncated and only their retained test segments are claimed.

## Unreleased — composition-bound static presentation

- Bind Pipeline cache authority, detached prewarm and mounted presentation to the same explicit `PipelineStaticPresentation` capability. Replacing an injected cache no longer warms or reads the process-global owner; same-owner rebuilds keep their mounted attempt and independent local rasters retain the same pure resize policy.
- Preserve the original cache/claim/generation owner and every scheduling/window/budget boundary. Extend the failing-first injected-cache integration regression through resident reuse and same-generation regrant.

## Unreleased — chapter boundary and latest trace regressions

- Correct Mihon logical chapter sequence while preserving newest-first source objects and opaque chapter/download identities. Source-owned order adaptation also covers persisted catalogs, so top/bottom traversal remains previous/next before metadata refresh.
- Reuse ReaderController absolute commands for chapter entry, give explicit entry precedence over historical viewport anchors, and confirm target layout and scroll range before acknowledgment. First/last entry aligns to the real boundary; physical dragging and controller replacement retire stale completion work.
- Preserve an already-published sealed WebP source at the final late-join boundary; the catch-up path no longer rebuilds the same complete source underneath native decode.
- Exclude overlapping same-manga Mihon catalog calls inside the runtime owner. Cancellation keeps active invocation lifetime until the Callable and uncancellable suspend continuation actually exit; other manga remain independent.
- Reader retention now delegates detached media retirement to Coordinator's existing lane barrier. It no longer evicts a native cursor while an admitted decode is still returning; idle media still retires immediately and active media retires automatically at physical exit.
- Add boundary reentry, legacy/fresh source order, sealed source identity and executable Kotlin catalog/cancellation regressions. Adjust two UI test fixtures for first-page boundary alignment and movement beyond real touch slop.
- Verify four device chapter crossings and four slider releases without vertical input, then the final Profile's animated exit and same-session reentry after 2.269s with no retained decode/upload instances or failures. Final required-toolchain checks, three-ABI debug/Profile builds and Rust22/22 pass; close RMR-027..031. Evidence: `docs/archive/audits/chapter-boundary-trace-regressions-2026-09-30.json`.

## Unreleased — static first-frame progress after slider release

- Fresh `2026-09-30T09-36-50` Trace exposes a downloaded static neighbor waiting behind a one-frame current source until scrolling promotes it to transition. Scope current bootstrap's cross-page block to animation waterlines; when a one-frame current cannot execute, release only existing one-frame neighbors or visible transition work through the same scheduler and bounded presentation grants (ADR0344).
- Add failing-first policy/Coordinator coverage, preserve animated-current and multi-frame-neighbor gates, and verify slider release progresses through Pipeline without another Reader observation. Source runtime open latency remains a separate observation, not a presentation fix claim.
- Fresh Profile verification also reproduces a final slider jump whose pointer-up precedes the post-frame navigation acknowledgment. A repeated offset emits no ScrollEnd and used to leave Reader in scrubbing/local-only indefinitely. Complete that released input phase at the same valid page-request boundary, preserving physical position/velocity, deferred ratio anchoring and real drag/scroll state (ADR0345).
- Synchronize the physical velocity baseline immediately after pointer-up flushes a different final slider target, so every release observation remains neutral for direction learning.
- Mounted offscreen PageHosts now honor the same raster-owner speculative admission denial as detached prewarming. This stops budget-eviction/regrant/reopen feedback without another tombstone, scheduler or larger cache; deadline/protected promotion still refills the same immutable generation (ADR0346).

## Unreleased — SAF body recovery authority and content proof

- SAF body 的 backup-only crash 状态不再因旧 index 已匹配预期 authority 而阻止 store 打开；仅在 backup 完整 length+CRC 匹配当前 authority 时恢复，不引入新 commit token。exact partial 重复保存由此恢复，physical partial 同长度保存仍保持既有幂等跳过。
- stale/crash SAF partial intent 恢复验证完整 CRC，拒绝同长度外部修改并保留 target/backup/intent；正常 live staging/index commit 的清理继续复用 copy proof，不增加正文扫描。
- Reader Kotlin compile guard 的 Android stub 补齐当前系统栏 API；保持生产 Reader 行为和真实 Android 构建门禁。
- 下载审计 DL-DIR-017/019 闭合：SAF focused 16/16、独立目录真机9组kill/reopen+1组physical幂等、最终required-toolchain gate通过（downloads504/504、App383+3既有skip、Android三ABI、Rust22/22）；测试目录已清理，原APK校验一致恢复。

## Unreleased — partial takeover and native worker degradation closure

- Reduce canonical SAF physical-partial takeover from three old-body passes to one hot-path copy: accumulate the obsolete-prefix CRC while copying into Direct staging, commit cleanup debt with that proof, and move delete-time SAF verification/removal to the existing asynchronous cleanup owner.
- Keep queued decode/source-write work when worker replacement fails but another worker is still live; decode preserves its final-slot current reservation. Decode pending rank now reads the existing scheduler `TaskControl.priority` at selection time instead of mirroring priority through a second subscription lifecycle.

## Unreleased — background execution ownership closure

- Re-audit background execution by measured blocking cost instead of defaulting to workers: remove version-candidate `Isolate.run` preparation/two-phase demand commit and the extra deferred source-wake queue; both are short owner-local control work and remain synchronous.
- Keep genuinely heavy native resident-source writes off the UI isolate: propagate the existing Reader-local ingress priority/cancellation through the source-write worker queue; queued cancellation withdraws pending work while in-flight native operations keep their slot until real completion.
- Split native decode/source-write worker lifecycle APIs. SQLite artifact object/replica/root metadata now stays as one short owner-connection transaction instead of a persistent read isolate; SQLite touch still enters through the existing storage-write scheduler before worker execution. See ADR 0328.

## Unreleased — vertical drag displacement resampling

- Re-open Flutter touch resampling only for finger-down vertical drag after new per-frame displacement diagnostics separated it from the previously falsified ballistic cadence hypothesis.
  With healthy ~8.3ms frames, matched constant-speed drag windows without resampling showed 9.9%–18.3% mean adjacent velocity change, 13–15 >20% jumps per window and maxima up to 255%.
  Flutter's built-in resampler reduced matched windows to 0 >20% jumps and <=0.0171% max while post-lift ballistic behavior stayed independently smooth.
- Restore the old `reader_runtime` ref-counted lease boundary: vertical continuous Reader enables `GestureBinding.resamplingEnabled`, final release restores the prior process-global value, and mode changes resync ownership.
  `reader` still cannot own framework input state; `samplingOffset`, custom interpolation/Ticker, forced frames, ScrollPhysics, geometry, Pipeline windows and NetLane remain unchanged.
  Device acceptance must include direct-manipulation latency because Flutter's default resampler deliberately trades some latency for uniform motion.

## Unreleased — vertical static ratio rebuild scope

- Stop amplifying each live source-canvas ratio publication into a whole `ReaderView` rebuild. Pending-only ratio facts now update state without dirtying widgets; a real vertical extent change invalidates only the ListView geometry subtree through a Reader-local layout revision.
- Preserve the existing scroll-stable prefix, decode-ahead future geometry, reverse-prefix `geometryCorrectionTarget`, idle top-pixel anchor and cached page shells. Encoded/decode/upload windows, NetLane, static warm and all Pipeline policy remain unchanged.
- Add a runtime-listenable regression that distinguishes zero-rebuild pending updates from ListView-local real extent changes; Reader navigation 24/24 and dev.280/dev.281/dev.287/dev.294/dev.308 gates pass. Fresh Profile/Release device verification of visible jitter remains pending.

## Unreleased — vertical scene-motion diagnostic gating

- Keep vertical idle static warming, the 3/7 one-frame intent envelope, initial six-screen composition pass, nominal `current±7` keepAlive and bounded recenter unchanged after re-auditing a power report; these are intentional staged preload/composition behavior rather than evidence of an 11-way media-work burst.
- Gate the Dart `verticalSceneMotion` RenderBox/global-transform sampler behind the existing `ZIC_READER_FRAME_CADENCE_DIAGNOSTICS` build flag, matching the already opt-in Android Choreographer/WindowMetrics diagnostics. Ordinary builds no longer run that pure diagnostic per-frame matrix probe.

## Unreleased — Reader settings model and Android system bars

- Replace the double-tap level-1/level-2 preset chips with 0.25x-step sliders while preserving the existing `defaultZoomStage1/defaultZoomStage2` persisted values and stage ordering.
- Replace the status-bar boolean with `显示 / 隐藏 / 跟随控制栏`. Legacy `showSystemStatusBar` persists as a read-only migration source; new writes use `systemStatusBarMode`, and follow-controls consumes the existing Reader controls visibility fact rather than creating another owner.
- Rework the Reader settings taxonomy around ownership instead of gesture-type mixing: layout now owns default mode, paged direction, adaptive policy and vertical stitching; interface owns initial control visibility and status-bar visibility; double-tap and long-press zoom have separate sections; detail-preview density moves out of Reader settings into Appearance.
- Add a global paged-direction preference with `LTR / RTL / 跟随来源`, defaulting to LTR. Per-comic explicit direction remains highest priority and high-confidence adaptive direction remains above the global fallback.
- Make long-press magnification an independent global value (default 2.0x) instead of silently borrowing the double-tap zoom stages. The configured scale is consumed by both paged and continuous Reader presentation without changing Pipeline demand ownership.
- Keep per-comic adaptive policy and manual overrides as independent axes. “使用自适应设置” remains visible after “启用本漫画覆盖”; clearing manual overrides no longer resets the adaptive switch/profile.
- Fix Reader system-bar ownership. The old one-shot route-transition gate prevented later control toggles/resume from reapplying system UI. The gate now defers only the first apply and permits subsequent reapply.
- Add a reader_runtime Android `WindowInsetsController` owner for status/navigation bars. This is required for Android 16 / targetSdk 36 where Flutter legacy non-edge-to-edge `SystemUiMode` calls are ignored. Explicit show/hide stays independent from Reader controls, while the new follow-controls mode deliberately mirrors them; the navigation bar follows control visibility. Exiting Reader restores both system bars.
- Device verification on Android 16 / targetSdk 36 confirmed status bars visible=true with the setting enabled, visible=false with it disabled, status remaining hidden when Reader controls are shown while navigationBars becomes visible, and both bars restoring on Reader exit.

## Unreleased — Mihon page-plan replay and dual-stack fallback DNS

- Give every newly generated Mihon opaque page locator stable chapter/page replay coordinates. Host-direct plans additionally carry an explicit `directPlanReplay` capability, so an expired direct URL can reuse the existing one-shot source recovery path to refetch the page list without adding a Reader/Pipeline retry loop.
- Treat previously persisted `mihon:resource:` locators without replay coordinates as legacy at the existing App source-compatibility gate, forcing a source page-list refresh before Reader/download consumption without changing `sourceRevision` or creating a synthetic comic version.
- Keep runtime-owned SSL/EOF semantics unchanged: only non-network, non-verification runtime source failures publish `sourceResourcePlanReplayEligible`; provider/network retries remain owned by DownloadJob.
- Harden runtime-owned Mihon resource-call cleanup by placing `call.execute()` under the same local try/finally that removes `calls[requestId]`; the outer FutureTask lifecycle remains the final cleanup fence.
- Stop forcing IPv4 to the front of system DNS results. Both network-bridge and Mihon-runtime fallback DNS now preserve non-empty system resolution order, use public fallback only after system failure/empty, and query both A and AAAA with interleaved fallback results. System answers are not public-filtered, preserving split-DNS/private-host authority.

## Unreleased — adaptive Reader behavior profile

- Correct the prior layout-only interpretation of adaptive reading after re-auditing VibeVenera: the per-comic “使用自适应设置” switch is independent from manual comic overrides, while the direction axis is only `跟随 / LTR / RTL / 纵向`.
- Keep adaptive profile learning active under a manual direction override. Direction overrides only direction; the same profile can still drive other Reader behavior and later typed consumers such as translation.
- Add long-press zoom as the first non-layout adaptive consumer: explicit comic override wins, otherwise high-confidence vertical/webtoon profiles disable it and paged/animated profiles enable it, then mode/global defaults provide the fallback.
- Generalize the old `verticalLongPressZoom` persistence into `longPressZoomOverride` with legacy read compatibility. Convert per-comic vertical stitching/long-press choices and the small global stitch/zoom enum choices to direct mutually exclusive pills instead of dropdowns.
- Preserve ZIC Pipeline ownership: adaptive does not alter NetLane, download/decode windows, prefetch admission, or transport lifetime.

## Unreleased — source settings ownership and comic layout policy

- Consolidate application-owned per-source policies behind one gear “源设置” entry: adaptive webtoon confidence, historical cache conflict trust, and per-source download placement. The previous configurable-source gear is now an attributes-list “来源属性与登录” entry, while plugin management returns to plugin lifecycle concerns only.
- Move historical carrier conflict trust from new plugin-scoped writes to `sourceTrustConflictingHistoricalCarriers[sourceId]`. Existing plugin overrides remain a runtime compatibility fallback; source-settings visits expand the old value to known sources without overwriting explicit source values, and retire the plugin override only when the installed-plugin authority proves the source set is complete.
- Move the download-directory UI from plugin rows to each source. Persistence and `DownloadRegistry.layoutResolver` were already source-scoped; the new UI therefore stops pretending that one plugin owns one directory. Existing durable bytes remain readable at indexed locators and are not migrated by this per-source setting.
- An initial pass replaced the per-comic adaptive switch plus direction dropdown with one layout-only chip policy. That interpretation is superseded by the adaptive Reader behavior-profile section above; source-settings ownership from this section remains current.

## Unreleased — bidirectional source webtoon confidence and VibeVenera parity

- Replace the one-sided source “webtoon weight” with a bidirectional 0–100% “条漫置信”: 0% is a strong paged prior, 50% is neutral/automatic, and 100% is a strong webtoon prior. The classifier consumes the signed prior symmetrically, so paged-only sources are expressible without adding a second setting.
- Read the previous `sourceAdaptiveWebtoonWeights=w` key as `sourceAdaptiveWebtoonConfidence=0.5 + 0.5*w`; this preserves the old vertical-vs-paged score difference exactly. Subsequent writes use only `sourceAdaptiveWebtoonConfidences`, with neutral 0.5 omitted.
- Complete the relevant VibeVenera source-metadata path: Venera `comic.adaptiveType` is normalized to typed `paged/vertical/animated` metadata in the isolated runtime descriptor, while App composition now projects source name, website and adaptive type into `AdaptiveReaderMetadata`. Mihon remains unknown unless it exposes an equivalent capability. The shared profile now mirrors VibeVenera's type-sensitive long-press gesture semantic; translation remains a future typed consumer, while Vibe-specific preload behavior is not copied across ZIC's Pipeline ownership boundary.

## Unreleased — adaptive layout source prior and segmented-page geometry

- Replace continuous geometry updates with a one-shot small-sample classifier in model v8. Reader samples at most three pages, includes page 0, decides once, then ignores later geometry for layout classification. Ratios in the ambiguous transport-slice band `0.65 < h/w < 1.20` (including 720×500 and 720×700) are neutral rather than paged evidence; clear 16:9/9:16 page shapes and long vertical pages retain their existing roles. Persisted pre-v8 profiles are invalidated through the existing model-version contract.
- Clear a stale adaptive profile from Reader session settings when its model/fingerprint is no longer current, then persist the new one-shot result when available; this prevents obsolete model output from lingering in per-comic settings while the runtime has already rejected it.
- Rework adaptive page geometry so near-square and mildly-landscape source slices no longer become paged evidence merely because they differ from 1:1. Model v8 keeps an explicit ambiguous `0.65 < h/w < 1.20` band; clear 16:9/9:16 page shapes remain paged evidence, the 1.9–2.2 portrait band remains deliberately uncertain, and truly long vertical pages retain strong webtoon evidence.
- Add a single per-source `sourceAdaptiveWebtoonWeights` preference (0–1) exposed as “条漫权重” in source management. The value is projected read-only through `ReaderSessionSettings`; Reader does not own or persist it. Non-zero weights participate in the adaptive-profile fingerprint, so changing a source prior invalidates stale per-comic automatic profiles without touching manual overrides.
- Treat `韩国/韓國/korea` only as weak webtoon evidence during geometry scoring rather than a hard layout or language classification. Model v6 introduced segmented-page ratio handling; model v8 adds one-shot bounded sampling and an explicit ambiguous transport-slice band. Focused regressions cover 720×500/720×700 slices, ordinary page ratios, long vertical pages, source-prior persistence and UI editing.

## 0.31.0-dev.329 - long-press zoom interaction settings and fixes

- Fix second-stage zoom bounds by resolving stage changes from the current
  scale/offset and clamping the target and animation frames against the
  scaled image rect. Continuous mode now treats a held second double-tap as a
  fixed horizontal-offset crop: horizontal dragging is disabled while held,
  the whole strip keeps the crop on release, and the next ordinary double-tap
  exits the lock.
- Long-press zoom is now user-settable end to end. Release behavior: restore-on-release (default, animates back to 1x and re-enables page scrolling) or persistent zoom (stays magnified until double-tap or page change). Move mode: drag (content follows cumulative finger travel x ratio; ratio defaults to 1.0 so the content follows the zoomed resolution 1:1, settable 0.25-4) or focus (the content point under the finger stays under it, t = p*(1-s)). Viewport limit ("max visible", default on): while dragging, if a scaled edge leaves through one side the opposite edge stays inside (translation clamped to [size*(1-scale), 0]); disabling allows free dragging past the viewport.
- Fix two real paged-mode defects: `_handleLensMove` re-applied the cumulative `offsetFromOrigin` every update (quadratic runaway that threw the page off screen with the slightest drag), and the outer raw pointer handlers cleared `_lensActive` before the long-press recognizer's end callback ran, so restore never executed and scrolling stayed locked after a magnify. Lens settle is now owned by the recognizer (`_finishPagedLens`, including `onLongPressCancel`), and `_animateTo` publishes the zoom state on completion so the InteractiveViewer unmounts.
- Continuous mode zoom (double-tap stages, pinch and long-press lens) acts on the whole strip through one uniform transform; pages can no longer be magnified individually. The strip lens now supports ratio/limit/focus modes, keeps receiving raw pointer positions for the whole gesture (the tap-candidate gate previously dropped every move after the first slop segment), and navigation commands/direction changes/controller swaps reset strip zoom.
- Change the default double-tap stages to 1.5x/2.0x (settings floor lowered to 1.1) and add a settable zoom-result position for double-tap: center (default), snap (the image edge on the tapped half aligns flush with that viewport edge; axes the scaled image cannot cover stay centered), and focus (the tap point stays put).
- Compute the "max visible" boundary constraint against the actual contain-fitted image rect instead of the page widget: letterboxed pages keep centered on axes they cannot cover, and coverage axes still clamp one-edge-out/opposite-edge-in.
- Continuous mode zoom becomes a viewport-space visual layer: scrolling stays enabled while zoomed (flip pages under the magnifier), long-press release no longer auto-restores, page jumps do not reset the strip zoom, and only structural changes (direction change/controller swap) reset it. The redundant single-finger pan was removed in favor of native scrolling.
- Fix three continuous-mode zoom defects: pinch release no longer snaps back to 1x when the result is below the old 1.15 threshold (accidental two-finger contact can no longer discard an existing zoom); a single-finger horizontal drag now pans the whole zoomed strip and locks its offset on release (the vertical component still belongs to native scrolling so pages keep flipping); and a long press on an already-zoomed strip no longer jumps to the magnifier scale - it drags horizontally per the configured move mode and locks the offset on release.
- Fix the real root cause of "double-tap zooms then shrinks": double-tap pairing compared shell-LOCAL positions, which drift while the strip zoom animation transforms the same screen point (measured distance ~50 > the 48px threshold), silently dropping pairs and cross-pairing the next taps into erratic stage jumps. Pairing now uses screen coordinates and stage progression uses a discrete index (-1/0/1), so rapid double-taps step monotonically 1x -> first -> second -> 1x regardless of animation timing.
- Implement the held-double-tap gesture: when the second press of a double-tap is held past the long-press threshold, apply that double-tap's target stage immediately and enter horizontal pan-lock; release keeps scale and offset. The pending single-tap timer is cancelled on the second press-down so holding can no longer toggle the controls.
- Fix the second "zoom then shrink" root cause on ordinary double-taps: deferred page-ratio commits (provisional -> measured) resized the strip content while the magnifier was active, which read as a spontaneous zoom-out. Ratio commits are now frozen while the strip is zoomed or lens-held and flush immediately on returning to 1x.
- A second pointer landing during a zoom animation now completes that animation instantly at its target scale instead of freezing mid-flight (the freeze looked like the zoom shrinking back).
- Horizontal panning is exclusive to held gestures (held double-tap / long press) and locks on release; plain single-finger horizontal swipes no longer pan the strip.
- Correct the continuous gesture semantics: an unlocked zoomed strip can pan horizontally with one finger again; a held second double-tap only locks the current zoom/crop and no longer advances to the next zoom stage, while a later double-tap unlocks without changing the stage. Paged InteractiveViewer updates now use the real contain-fitted image rect for boundary clamping at every zoom stage.
- Fix the double-tap animation order: resolve the settled frame (scale AND centered offset) up front and interpolate straight onto it, instead of animating the offset toward zero and snapping back afterwards.
- Restore plain single-finger horizontal swipes panning the zoomed strip (offset persists). During a held double-tap / long press the gesture owns the pointer: vertical page flipping is suspended for the duration (NeverScrollable while held, restored via setState on release) and the release locks scale plus offset.
- Root-cause the second-stage offset/bounds defect: the keep-focal-point formula omitted dividing by the CURRENT scale (`t' = f - s'*(f-o)` instead of `f - s'*((f-o)/s)`). Stage one (o=0, s=1) masked it; entering stage two reused the stage-one offset as if the view were at 1x, landing far out of bounds. The zoom animation also interpolates the offset per-tick through the live-scale clamp so intermediate frames can never exceed bounds.
- Final lock semantics: plain single-finger horizontal swipes never change the offset - the locked horizontal crop (fixed comic edges) can only be adjusted via a held gesture and stays locked on release.
- Settings flow through app preferences (`longPressZoomRestoreOnRelease`/`MoveMode`/`PanRatio`/`LimitToViewport`) into `ReaderSessionSettings` and `ReaderView`; reading settings screen exposes four new controls. Regressions in `packages/reader/test/reader_zoom_test.dart` (9 cases) and the preferences round-trip test.

## 0.31.0-dev.325 - current-role satisfied-static scheduler boundary

- The user-local 05:33 dev.323 trace plus the new visual localization moves the fixed hitch from generic final-presentation cadence to the discrete previous/next -> current role-promotion boundary. The 36 matched promotions occur at `pageTransition.currentCoverage` median 0.507 (0.501–0.526), confirming that the visual three-zone report points at the discrete promotion seam even though the code threshold is near equal two-page coverage. `pageCurrent`-associated reconciles are 3.895ms median (32/36 >=3ms, max 5.838ms) versus 0.687ms median for the other 80 reconciles; a typical boundary migrates download 1/4/1, decode 1/3/1 and upload 1/3/1 and starts two UploadLane tasks even though the involved pages are already authoritative resident static outputs.
- Treat role/priority migration of an already-satisfied one-frame static page as scheduler metadata rather than media work. LiveCoordinator now skips DecodeLane re-follow when the exact DecodeSession is already satisfied and has no pending source revision, and UploadSession/UploadRegistry can adopt a ready retained static output into the new demand revision/role without enqueueing another UploadLane prepare. Missing frames, pending source revisions, animation, failure/dispose, decode generation changes and in-flight prepares retain the full path.
- Add `tool/analyze_current_role_boundary_jank.py` and direct/static-revisit regressions. This version intentionally does not move the current-page geometry boundary and does not yet change startup artifact-pressure hold/release; the next same-device trace must test whether current-boundary reconcile/lane starts collapse before that second control-plane component is touched. Perfetto remains optional evidence only because the user device has no Perfetto.

## 0.31.0-dev.324 - SurfaceFlinger Perfetto evidence boundary

- The 05:33 dev.323 high-refresh device trace is valid (`taskFailed=0`, `big_5x5=0`) and closes the retained-static re-projection hypothesis as a sufficient root: all 10 active direction flips have `resident_static_represent total=0/associated=0`, while the same fixed-position hitch remains. Keep the dev.323 fast path, but do not widen current±2 presentation continuity or change keepAlive.
- Existing observation-only audits now converge on the final presentation boundary: 2,480/2,487 Android cadence intervals are <10ms; Flutter summary cadence is 8.319ms over 2,398 samples; 2,190 vertical scene samples are valid with zero residual outliers; the only 27.926ms ScrollUpdate gap has no active-scroll Window FrameMetrics counterpart. This is not evidence for another Reader/Pipeline policy change.
- Add an observation-only Android API31+ Perfetto capture using `android.surfaceflinger.frametimeline`, active SurfaceFlinger layer snapshots with composition/HWC/buffer flags, app/system gfx/view tracing, and process stats. Add an offline FrameTimeline analyzer that summarizes per-layer actual-present gaps, late/jank tags, fence state, GPU composition and SurfaceFlinger actual frames. Production Reader/Pipeline/texture behavior is unchanged.

## 0.31.0-dev.323 - retained static re-projection boundary

- The valid 03:35 dev.322 device run restores complete loading (`taskFailed=0`) and proves the active download bridge did its intended transport work: 26 active direction flips have `big_5x5=0`, median add/remove 1/1, and flip reconcile median/max 4.617/5.874ms, yet the user still reports the same fixed-position hitch. Keep the bridge as a bounded control-plane optimization but close it as a sufficient jitter root; do not tune its quota.
- All 26/26 active direction flips are followed within 15ms by exactly two authoritative-static `framePipelineTiming` presentations with `platformResidentReuse=true`. Across those flips the two redundant presentation paths cost 1.886ms median and 4.785ms max combined, with no blit, Surface reconfigure or platform upload. The retained OutputFrame/texture lease is already resident; only the page projection claim was dropped and later reacquired.
- On static re-entry, acquire a fresh PresentClaim for lifetime ownership but, only when the exact retained OutputFrame is authoritative static and already has successful presentation timing, project it directly without calling `OutputFrame.present()` again. First presentation and every animated frame remain unchanged. Add a direct UploadSession regression and `tool/analyze_resident_static_reprojection_jank.py`.

## 0.31.0-dev.322 - active download bridge fixed-list mutation repair

- The 02:50 dev.321 device trace is invalid for jitter attribution because 6,463/6,463 `taskFailed` events are `reader-observation-reconcile` failures with `Unsupported operation: Cannot remove from a fixed-length list`. The bridge built `missingDesired` with `toList(growable: false)` and then called `removeAt(0)` whenever one speculative identity needed to advance, aborting the whole reconcile and leaving many images without fresh demands.
- Keep the dev.321 bridge design unchanged, but make speculative advancement non-mutating: select `missingDesired.first`, remember a start index, then fill remaining desired entries by index. Add a direct PipelineController regression that performs active vertical committed-page movement, requires normal completion, keeps every decode/upload DownloadId present, and observes `downloadBridgeDesiredAdvanced=1`. The direction-flip analyzer now marks any task-failed run invalid before performance interpretation.
- The dev.321 02:50 run must not be used to claim jitter relief. Re-run the same fully loaded 12↔14 high-refresh interval on dev.322; only after `task_failed=0` and all pages load may the 5/5 churn/reconcile/jitter hypothesis be evaluated.

## 0.31.0-dev.321 - active download-window bridge boundary

- The dev.320 01:31 high-refresh trace closes general scene-motion drift while exposing a repeatable fixed-position control transaction: 13/13 active read-direction flips perform `downloadAdded=5/downloadRemoved=5/downloadChanged=6`; flip reconcile median is 7.455ms and max 9.669ms against an 8.333ms 120Hz budget. Repeated page12/page14 flips also re-project resident static pairs without physical blit.
- Keep the canonical desired encoded 7/3 window, decode 2/1, two-page direction predictor, dev.317 `Timer.run`, native texture and immediate current/visible/transition semantics. During vertical dragging/scrolling/settling only, bridge the physical encoded-download plan: all sources required by desired decode/upload/current/transition enter immediately, while encoded-only desired membership advances at most one new identity per committed current page and previous speculative identities temporarily fill unused capacity. Idle fully converges to canonical 7/3.
- Add bridge telemetry and `tool/analyze_direction_flip_120hz_jank.py`, ADR 0300 and the dev.321 audit. This is not dev.316 hysteresis and not a time debounce: direction changes immediately; only far transport membership migration is amortized. If 5/5 churn collapses but fixed-position jitter remains, do not tune the quota/threshold; test static projection continuity independently.

## 0.31.0-dev.320 - vertical scene-motion frame boundary

- Treat the 23:59 trace strictly as high-performance-device evidence: Choreographer is 2052/2064 <10ms (mean 8.419ms), non-zero ScrollUpdate is 1989/2047 <10ms, and Flutter framework/raster phases are usually small.
- Correct dev.319 interpretation: only 62 Window FrameMetrics were observed and eight exported outliers are four duplicate vsync callbacks, all before active scrolling; startup UNKNOWN_DELAY is not promoted to the scrolling root cause. Window metrics now deduplicate identical vsync callbacks and expose first/last-vsync coverage.
- Keep dev.317 ordinary-event-turn observation draining and existing native-texture presentation. Add observation-only active-scroll post-frame scene sampling of live ScrollPosition plus current RenderBox transform; aggregate the seam-invariant `globalTop + pixels - expectedStart` into `verticalSceneMotionSummary/Outlier`. No Reader/Pipeline/rendering policy changes.
- Add `tool/analyze_vertical_scene_motion_jank.py`, ADR 0299 and the dev.320 high-performance audit. If scene motion is continuous on-device while stutter remains, the next boundary is actual SurfaceFlinger/Perfetto presentation rather than another Flutter framework tweak.

## 0.31.0-dev.319 - Android Window FrameMetrics observation boundary

- The 16:22 dev.318 trace validly falsifies the static Flutter projection rather than repeating dev.315's planner failure: 11/11 authoritative classifications are `animated=false/frameCount=1/complete=true`, `staticFlutterPresentation` occurs 12 times and `taskFailed=0`, yet the Reader problem remains. Restore dev.317 native-texture static presentation; retain dev.317 `Timer.run` and dev.318 `scrollCadenceSummary` observation only.
- Motion itself follows delivered app cadence: 2,006 non-zero ScrollUpdate intervals contain 1,521 at 14-18ms while 2,205 Android Choreographer intervals contain 2,096 at 14-18ms. Ninety-seven platform outliers have 26.294ms median system gap and 76/97 spend less than half of that gap in Android main-thread CPU. Build/Layout/Paint/raster remain small, so do not tune 180ms, physics, renderer, prefetch direction or frame-rate policy.
- Add observation-only Android Window `FrameMetrics` on a dedicated `zic-reader-window-metrics` HandlerThread. Record total/unknown delay/input/animation/layout/draw/sync/command-issue/swap timing plus API26+ intended/actual vsync into bounded `platformWindowFrameMetricsOutlier` / `Summary` traces. The callback's `droppedReports` is metrics-report loss, never interpreted as display dropped frames; these events never schedule a Flutter debug frame or drive Reader/Pipeline state.

## 0.31.0-dev.318 - Static WebP Flutter projection composition boundary (FALSIFIED / rolled back in dev.319)

- Preserve dev.317's event-turn benefit and keep the full Pipeline/native UploadDemand/SurfaceProducer path while testing only final static presentation: after authoritative one-frame WebP classification and a ready native Texture, load the same compressed artifact through Flutter `MemoryImage/ResizeImage` and switch only after the Flutter image's first frame. Unlike dev.315, the exactly-one-current-per-lane invariant remains intact.
- Add observation-only `scrollCadenceSummary` to measure actual non-zero ScrollUpdate cadence separately from Choreographer/Flutter frame cadence. The explicitly identified high-performance 15:16 control has 4,761/4,772 Android intervals below 10ms and Flutter timing near 8.319ms despite residual subjective jitter.
- Device result is negative: the 16:22 run produces 12 `staticFlutterPresentation` events with zero `taskFailed`, but the problem remains. The route is therefore FALSIFIED; dev.319 restores native-texture static presentation while retaining the useful motion-cadence summary.

## 0.31.0-dev.317 - Reader observation ordinary-event-turn boundary

- The 14:39 dev.316 device trace falsifies prefetch-direction hysteresis as the visible-jank root: 5-add/5-remove working-set flips fall from 20 in the prior stable trace to 7, yet UI jank remains. dev.317 therefore restores the dev.313 two-committed-page browsing-direction predictor instead of tuning another threshold.
- Of 84 non-summary `readerFrameTiming` samples, 66 have `frameIntervalMicros >= 20000`; 55 of those still have both build and raster below 3ms, and 3 have both below 1ms. The dominant miss can therefore occur between cheap Flutter framework frames rather than inside Build/Layout/Paint. Existing audits already place Reader observation plan/reconcile/lane-pump work on the Dart UI isolate after `scheduleMicrotask`.
- Preserve latest-wins observation coalescing and immediate Reader viewport/current/transition state, but drain the observation queue with `Timer.run` instead of `scheduleMicrotask`. This adds no fixed 180ms delay: it yields one ordinary event-loop turn so platform/input/vsync events are not necessarily starved behind a frame-end Pipeline microtask transaction. Source-kind/refill/animation microtasks remain unchanged for single-variable attribution. Renderer/native texture, local-static pre-presentation, 7/3, decode 2/1, NetLane, geometry and ScrollPhysics remain unchanged.

## 0.31.0-dev.316 - Prefetch direction hysteresis boundary (FALSIFIED / rolled back in dev.317)

- Roll production media/presentation behavior back to dev.313: dev.314 did not solve the jitter and moved first static copies onto visible transition seams; dev.315 still did not solve it and introduced 378 `reader-observation-reconcile` failures (`a plan must contain exactly one current demand per lane`). Static WebP is again the one-frame case of the unified native-texture pipeline; dev.314/dev.315 remain historical evidence only.
- Reconstructing the stable 11:45 dev.314 `readerFrameTiming` batches onto Reader monotonic time isolates a UI-isolate cost that matches the user's VibeVenera DevTools comparison. Twenty 7/3 working-set direction flips each perform `downloadAdded=5/downloadRemoved=5`; those reconciles have 7.425ms median versus 1.289ms for other reconciles. Nine of sixteen frames with build>=10ms land within +/-15ms of such a flip; near-flip build median is 14.617ms versus 1.637ms away from flips.
- Keep current/visible/transition viewport state immediate, but separate it from asymmetric prefetch intent. `BrowsingDirectionPredictor` now requires four cumulative committed-page steps in the opposite direction before flipping the 7/3 orientation. Encoded window size 7/3, decode 2/1, NetLane, ScrollPhysics, geometry, texture presentation and frame-rate policy are unchanged; no 180ms debounce is introduced.

## 0.31.0-dev.315 - Static WebP encoded Flutter presentation boundary (FALSIFIED / rolled back in dev.316)

- The 11:45 dev.314 low-performance-device trace falsifies hidden-next2 upload timing as the fixed-position root: 173 scroll cadence outliers remain after active hidden static warming is suppressed. All 14/14 authoritative classifications are static (`animated=false`, `frameCount=1`, `complete=true`), while first visible transition texture copies still cost up to 16.588ms and every positive platform blit sample has `surfaceReconfigureCount=1`.
- Remove the static WebP SurfaceProducer first-copy from the Reader path instead of moving it between roles. Once transport has observed WebP, Android texture upload waits for decoder animation truth; `animated=true` keeps the existing native texture path, while `animated=false` loads the existing Pipeline artifact's compressed bytes through Flutter `MemoryImage`/ImageProvider.
- This is not the dev.311 native-RGBA-to-`decodeImageFromPixels` experiment: native decode remains for classification/prewarm, but static presentation consumes original compressed bytes. 7/3, decode 2/1, NetLane, geometry, ScrollPhysics and animated WebP remain unchanged.

## 0.31.0-dev.314 - Fixed-position hidden static upload boundary (FALSIFIED / rolled back in dev.316)

- The 10:26 dev.313 low-performance-device trace changes the root-cause priority: 148 scroll cadence outliers cluster strongly by content index (currentIndex 20: 42; 12: 19; 22: 15; 23: 13), matching the user's repeated same-position reproduction. Native Choreographer still runs mostly at 14-18ms, but that global cadence cannot explain deterministic content-position hotspots and is retained only as a background amplifier.
- Re-open only the active hidden-static presentation exception from dev.308. A concrete page-11 classification edge at 40.658911s (`animated=false`, `localPresentationReady=true`) immediately added hidden `next2` upload; its 712x2336 Android texture blit consumed 16.163ms and completed at 40.677365s immediately before a 32.845ms scroll cadence gap. Across correlated physical uploads, 16/19 are `next2`.
- During vertical dragging/scrolling/settling, keep hidden static neighbors decoded but never start speculative texture upload solely because local/durable static classification becomes authoritative. Current/transition/actually-visible static pages still upload, and idle restores bounded pre-presentation. Encoded 7/3, decode 2/1, NetLane, ScrollPhysics, geometry and Reader position remain unchanged. This is a single-variable falsification; the proposed 180ms Pipeline control debounce is deliberately not included.

## 0.31.0-dev.313 - Platform-vsync effective cadence boundary

- Cross-device dev.312 evidence rejects ARR as the shared root: the low-performance API36/120Hz device has `displayHasArrSupport=false` and still reproduces, while the high-performance ARR-capable device still reproduces with the dev.312 policy confirmed applied. Production Reader therefore stops activating the ARR intervention; its adapter/evidence remain for history.
- Existing Flutter healthy timing is ~16ms on both 120Hz devices, including high-device dragging, so a simple touch-held 120Hz to post-lift 60Hz switch is not supported. The high-performance device has a 28.606ms ballistic median and many low-main-thread-CPU platform misses, further downgrading raw compute starvation.
- Extend the observation-only `android.view.Choreographer` probe with a two-second `platformFrameCadenceSummary` over every native interval using fixed cadence bins. The next run decides whether Android/OEM gives the app ~16.7ms cadence or Flutter consumes ~16ms frames from a ~8.3ms native cadence. No frame-rate request, touch-boost toggle, forced frame, ScrollPhysics or position smoothing is introduced.

## 0.31.0-dev.312 - Android ARR ballistic boundary

- Falsify dev.311 renderer topology on device: all 48 sampled pages use `renderer=flutterImage`, yet 57/72 scroll cadence outliers remain post-lift ballistic and 70/87 platform cadence outliers still contain >=20ms Choreographer system-frame gaps. Roll production Reader presentation back to the already-known dev.310 Android texture default to remove the added Flutter-image output-preparation cost; that rollback is not a candidate fix because dev.310 already reproduced the bug.
- Fix `ReaderRuntimePlugin.kt` to import `android.view.Choreographer`. Extend cadence outliers with main-thread CPU-gap and display-refresh metadata while keeping the probe observation-only.
- Add a separate Reader-scoped Android API 35+ adaptive-refresh policy: while a vertical Reader is mounted, save and disable `Window.isFrameRatePowerSavingsBalanced`; restore the exact prior value on exit/activity detach. Record `platformFrameRatePolicy` start/stop evidence so the next device A/B cannot be interpreted unless the policy actually applied.

## 0.31.0-dev.311 - Reader Flutter-image presentation boundary

- The 08:58 dev.310 device Trace confirms the handoff split lands on Android/Choreographer cadence: 38/53 scroll cadence outliers are post-finger-lift ballistic, while 58 `platformFrameCadenceOutlier` samples include repeated 20–66ms system-frame gaps. Most platform misses do not overlap traced decode/reconcile/present work, so further Reader control-plane tuning is not the primary route.
- Treat VibeVenera as a renderer-topology control rather than citing old Flutter issues as root cause: its continuous reader builds ordinary `ComicImage(ImageProvider)` / Flutter ImageStream pages, while this ZIC run uses `androidTexture` for every recorded static Pipeline frame.
- Keep native source/cursor/libwebp decode, but make the production `NativePipelineMediaRuntimeFactory()` project through the existing Flutter `ui.Image` / `RawImage` path. Retain SurfaceProducer output only behind explicit `NativePipelineMediaRuntimeFactory.platformTexture()` diagnostic opt-in; standalone Animated WebP texture playback is unchanged. Reader geometry, ScrollPhysics, touch sampling, 3/7, decode 2/1 and NetLane stay frozen.

## 0.31.0-dev.310 - Ballistic platform frame-cadence boundary

- The 08:20 dev.309 device Trace falsifies touch sampling as the main vertical jitter owner: 20/22 `scrollCadenceOutlier` events are `dragDriven=false` ballistic updates after finger lift, with a 28.2005ms median and 42.888ms max. Their pixel deltas follow the inertial trajectory rather than showing discrete position jumps.
- Roll back the dev.309 `GestureBinding.resamplingEnabled` lease while retaining `dragDriven` attribution. Do not tune sampling, synthesize positions, force Flutter frames or alter ScrollPhysics.
- Add an observation-only Android Choreographer cadence probe owned by `reader_runtime`. Native code records only >20ms frame/callback gaps or >8ms callback lag into a 256-entry ring; Dart drains it every 2s and maps native monotonic timestamps into the existing Reader Trace as `platformFrameCadenceOutlier`. The probe never drives Reader/Pipeline state or schedules Flutter frames.

## 0.31.0-dev.309 - Vertical Reader touch resampling and cadence attribution

- The 05:24 dev.308 device Trace mechanically closes the local-static preparation regressions: page19/page20 are firstFrameReady about 963ms/764ms before first transition, and sampled page extents no longer change from provisional to measured values. Strong jitter nevertheless remains.
- Raw vertical ScrollUpdate cadence is now the strongest signal: 49 non-zero `scrollCadenceOutlier` events have a 31.775ms median, 36.668ms p90 and 75.923ms max; many matching ~30-36ms Flutter frames have only ~1-3ms build/raster/vsync overhead. Enable Flutter built-in touch resampling only through a ref-counted `reader_runtime` lease while vertical continuous Reader is active, restoring the prior global value on final release. Do not tune `samplingOffset`, synthesize positions, force frames or alter ScrollPhysics.
- Preserve drag semantics on ScrollUpdate (`dragDetails != null` => `Interaction.dragging`) and record `dragDriven` on cadence outliers. This makes the next device run distinguish touch sampling mismatch from ballistic/engine frame cadence without changing Pipeline's existing vertical active scheduling class.

## 0.31.0-dev.308 - Local static pre-presentation and reverse geometry preparation

- The 04:45 dev.307 device Trace exposes a new local-image regression: page hosts can be mounted hundreds of milliseconds early while authoritative static presentation is still withheld until the page becomes a real transition. Page19 enters transition at ~38.554s and reaches firstFrameReady at ~38.605s; page20 enters at ~39.247s and becomes ready at ~39.299s. Their encoded bodies are already immutable local/durable authority, so dev.295 generic hidden-static active-scroll deferral is too broad for this case.
- Keep dev.295 deferral for generic/network/unresolved hidden static pages, but allow a page already inside the existing stable decode/static-output window to pre-present during active vertical scrolling only after the decoder authoritatively reports animated=false and the encoded body is direct immutable local or residentBodyBacked. This does not create extra DecodeDemand, widen 2/1 or 3/7, or apply to animated/unresolved pages; retain the prepared static output inside the existing bounded output budget.
- The same Trace proves fast reverse traversal can still use provisional one-screen geometry despite physical sourceCanvas having resolved earlier: page17 is measured at 960x3450 around 11.857s yet first appears with ~924.44px extent before later using ~1533.23px; page19 similarly uses ~924.44px before ~1433.28px. Make decode-ahead ratio adoption direction-aware: higher-index future extents after visibleMax remain safe without correction, while lower-index incoming extents before visibleMin may enter the active geometry only with atomic layout-time top-anchor correction. Visible-page ratios remain frozen until idle; no jumpTo/interpolation/ScrollPhysics tuning.

## 0.31.0-dev.307 - Reader position/lifecycle boundary and scroll-cadence observability

- The 04:12 dev.306 device Trace isolates the strong pre-exit jitter segment. Around 30.450s a ~29.5ms frame interval contains ~13.8ms Flutter build plus current 22→23, rev150 reconcile (~4.67ms) and page-host retirement/mount work; meanwhile ~29.945s/~30.042s still show ~29.5/~32.2ms intervals with only ~1–2ms build/raster. This proves a current-boundary rebuild amplifier exists but low-build cadence gaps remain a separate engine/input scheduling candidate.
- Split ReaderController command notification from current-page projection: report() publishes currentIndex through a narrow ValueListenable and no longer wakes direction/rotation/navigation command listeners. Page active state, progress projection, subtitle/scrubber/playback capability subscribe narrowly; whole controls no longer rebuild on every current crossing.
- Keep vertical current±7 page-host retention bounded but freeze its center during one active scroll and commit the new center at idle/explicit navigation, so far-host demotion/dispose does not compete with the current-crossing build. Add export-only scrollCadenceOutlier for raw ScrollUpdate gaps >20ms; do not alter ScrollPhysics or smooth/interpolate position.

## 0.31.0-dev.306 - Vertical continuous viewport/control-plane separation

- The 03:32 dev.305 device Trace confirms the scheduling-migration fast path reduced common 1-added/10-changed/1-removed reconcile median from about 8.39ms to 4.73ms, yet strong visible jitter remains. Layout probes stay stable while several 30-45ms active-scroll frame gaps contain no policy/reconcile/texture/page-host event, so sessions/reconcile micro-optimization is now a secondary amplifier rather than the primary explanation.
- Audit the untraced per-observation path: roughly 1,197 Reader observations produced only 132 policy decisions, but every observation still entered ReaderBinding/PipelineReaderSession, rebuilt playback identity maps, scanned playback state, refreshed page-stream/output/artifact schedulers and emitted high-frequency Reader/transition diagnostics. Separate continuous vertical geometry from discrete Pipeline control state: fraction/velocity/logical-position-only motion no longer enters Pipeline; vertical active playback uses continuous viewport semantics; playback and page/output control synchronization run only when viewport semantics, plan revision, current identity or decode target actually change.
- Reduce already-falsified diagnostic overhead without deleting evidence: readerObservation/pageTransition are source-sampled at semantic edges or 250ms, and the dev.294 layout probe keeps start/end plus a 500ms active heartbeat instead of 10Hz. No geometry, ScrollPhysics, sourceCanvas, texture/presentation, 3/7, decode2/1, NetLane or scheduling priority changes.

## 0.31.0-dev.305 - Scheduling-migration control-plane fast path

- The 02:44 dev.304 device Trace keeps vertical geometry mechanically stable (`extentDeltaPx=0`, constant layout residual and identity transforms) while pronounced missed-vsync remains. Exported `readerFrameTiming` represents about 923 real frames; retained jank still reaches ~85.5ms while many 30-35ms gaps have only ~1-3ms build/raster. This keeps UI-isolate/control-plane work as the primary path and does not support reopening the position-jump/geometry hypothesis.
- Legal page-boundary reconcile is still expensive after dev.301-304: 87 accepted reconciles have a 2.319ms median overall, but the 15 common `1 added / 10 changed / 1 removed` download-window migrations have an 8.387ms median and 11.284ms max. Existing identities were still re-emitting per-demand scheduling telemetry, re-entering ingress/source-watch observation, and running full physical-claim establishment code for role/priority-only migration.
- Separate scheduling migration from lifecycle establishment. Existing-scope download priority changes no longer emit `demandApplied`; changed decode/upload demands remain visible through aggregate `pipelineReconcileTiming` instead of per-demand lifecycle trace. LiveCoordinator observes/attaches ingress only for new or actually replaced physical DownloadSession identities. DownloadTransferOwner uses a scheduling-only existing-claim fast path only while physical/exact identity, checksum proof and completion intent remain unchanged; identity/proof/completion changes still use the full claim path.
- Keep policy, priorities, 3/7, decode 2/1, NetLane capacity, sourceCanvas, vertical geometry, texture/presentation and dev.299 current±2 continuity unchanged. Some long frame gaps contain no traced reconcile, so dev.305 is device-falsifiable control-plane reduction rather than a claim that every remaining missed-vsync cause is already closed.

## Working tree - vertical frame-cadence follow-up

- 固定纵向 page shell composition 为 6 个 viewport，移除 idle post-frame 渐增 warmup，避免手势前的大范围 sliver rebuild。
- Debug trace 摘要使用 O(1) 导出事件计数，不再在每次 trace 事件上排序完整导出缓冲；恢复 Reader 方向/旋转变更遗漏的局部重建。
- `readerFrameTiming` 的健康帧按约 1 秒摘要保留样本数与 min/max，build/raster/span 超预算或 vsync 间隔达到 20ms 的帧逐条保留；异常帧会切断健康摘要桶，避免诊断自身撑满 UI/export ring。

## 0.31.0-dev.304 - Constant-time diagnostic trace hot path

- After dev.301–303 removed semantic revision churn, repeated lane pumping and hidden snapshot broadcasts, the reported vertical scroll drops still remain while recorded Flutter build/raster time is usually low. The remaining legal page-boundary path synchronously emits many demand/observation events on the UI isolate, so diagnostic processing itself is now treated as frame-budgeted work rather than free instrumentation.
- Make locator sanitization cheap for ordinary events: Venera/Mihon regular expressions are compiled once and skipped unless a string contains the relevant scheme marker. Preserve all existing opaque-locator redaction behavior.
- Replace Debug Trace's shifting 500/10000-entry lists with O(1) bounded queues and live export-bucket entries; evict stale bucket keys, merge only numeric fields present in the incoming event, and do not request a Flutter frame when no trace viewer is listening. Export ordering, semantic buckets, error/lifecycle retention and min/max summaries remain unchanged.
- Remove PipelineReaderSession's unconsumed, unbounded private MemoryTraceSink copy while keeping the ref-counted shared physical trace and explicit App sink. MemoryTraceSink itself now supports optional O(1) bounded retention. Also fix the existing Pipeline runtime ownership test's missing direct `pipeline` import instead of widening production exports.

## 0.31.0-dev.303 - Download trace / snapshot publication boundary

- 12:56 dev.302 device Trace falsifies the assumption that repeated lane pumping was the dominant legal-revision cost: the common 1-added/10-changed/1-removed page-boundary reconcile still has a roughly 10.213ms median, 12.03ms p90 and 13.079ms max, essentially unchanged from dev.301 despite `atomicLaneBatch=true`.
- Root cause is a hidden `DownloadSession._emit()` side effect. dev.302 changed priority-only demand migration to avoid an explicit `_notifySnapshot()`, but `_emit()` itself still unconditionally published a full `DownloadSnapshot`; new-scope/detach paths could therefore publish twice. Pure flow-control/read-permit/resume/source diagnostic events also woke PageStream/progress/retention observers.
- Split diagnostics from authoritative projection: `_recordTrace()` never publishes snapshots. State/content/demand-count boundaries publish exactly once via explicit `_notifySnapshot()`; priority-only scheduling migration and diagnostic-only transport/source events publish zero snapshots. `bytesCommitted` keeps bounded progress publication at the existing source-progress quantum.
- Keep dev.302 lane batching and all Reader resource/presentation policy unchanged. Existing `pipelineReconcileTiming` remains the device falsification signal; no new visual or resource workaround is added.

## 0.31.0-dev.302 - Atomic lane reconcile transaction

- 12:21 dev.301 device Trace confirms the dev.301 semantic-no-op revision cascade is mechanically gone, yet pronounced vertical jitter remains as missed-vsync: 43 frame intervals exceed 30ms overall and 37 occur during active vertical interaction. 28/37 active long gaps fall within 100ms after a real `policyDecision`.
- A legitimate page-boundary revision still fans out synchronously on the UI isolate: common 11-download updates plus 4 decode and 2 upload mutations take roughly 10-15ms before normal build/raster. Each Net/Decode/Upload mutation previously called `_Lane._pump()` immediately, repeatedly scanning/admitting against intermediate state.
- Treat one accepted `DemandPlan` as one scheduler transaction. `TaskLane.batch` applies mutations immediately but defers pumping until the outer batch commits; `LiveCoordinator` batches Net/Decode/Upload reconciliation so each lane pumps only against final authoritative state. Pure download-priority migration also stops rebroadcasting the full media/session snapshot to PageStream/progress/retention observers. Policy, 3/7, decode 2/1, priorities, NetLane capacity and presentation continuity are unchanged.
- Add diagnostic-only `pipelineReconcileTiming` for accepted revision duration/diff cardinality. Recording this timing, like `readerFrameTiming`, must not request a new Flutter frame.

## 0.31.0-dev.301 - Semantic demand revision boundary

- 11:43 dev.300 device Trace finally exposes a frame-cadence root cause at the scheduling boundary: Flutter misses repeated 2-4 vsync intervals while build/raster are usually only a few milliseconds. During the same scroll windows, offscreen WebP sniff/classification evidence produces forced policy revisions whose 11/4/2 resource plan is semantically unchanged, yet expiration-only revision churn re-emits all decode/upload demands on the UI isolate.
- Separate scheduling identity from liveness metadata. `DemandDiff` ignores `expirationRevision`, `LiveCoordinator` refreshes surviving demand expiration in-place without cancel/submit/follow, and download transfer reconciliation is skipped when the download scheduling diff is empty.
- `PipelineController` now builds a candidate plan before committing revision; runtime evidence that leaves roles/resources/priorities/watermarks/flow/keep unchanged does not advance revision, emit `policyDecision`, or enter coordinator reconcile. Keep actual media evidence for future decisions.
- Correct FrameTiming observability: Flutter batches historical timings, so Reader no longer stamps callback-time scroll/current/interaction onto every frame. Trace keeps engine timing plus batch monotonic anchors for honest timeline reconstruction.

## 0.31.0-dev.300 - Reader frame timing adapter boundary

- Fix the dev.299 local Flutter compile failure where `ReaderView` referenced `FramePhase.vsyncStart` without owning/importing the dart:ui timing API. Do not patch this by importing engine enums into the Reader widget.
- Introduce a framework-neutral `ReaderFrameTimingSource` / `ReaderFrameTimingSample` contract in `reader`; move `SchedulerBinding.addTimingsCallback`, `dart:ui.FrameTiming` and `FramePhase` parsing into the `reader_runtime` Flutter presentation adapter. Reader keeps only scroll/current/interaction correlation and Trace emission.
- Preserve dev.299 direction-stable `current±2` static presentation continuity unchanged. Frame timing remains diagnostic-only; it does not drive geometry, navigation, Pipeline, decode/upload policy or scheduling.

## 0.31.0-dev.299 - Direction-stable static presentation continuity and frame cadence telemetry

- The 10:27 dev.298 device Trace shows dev.298 was only directionally effective: actual page layout remains stable, but previously presented authoritative static frame 0 still re-enters platform presentation as zero-copy resident reuse. Page14 is already presented, then current moves 14 -> 13 -> 12 with readDirection=-1; page14 remains only two pages away yet drops out of the directional previous1/next2 decode plan, clears its UI projection, and is re-presented when it becomes visible transition again. The page host itself stays mounted.
- Keep the existing directional decode previous1/next2 policy unchanged, but make already-presented static UI continuity direction-stable within the union of those directional windows: current±2. This envelope may retain only an existing authoritative static surface/PresentClaim; it creates no DecodeDemand, UploadDemand, decode session, upload work or present call, and releases outside ±2 or on target/generation/dispose/listener invalidation.
- Add Reader-owned Flutter `FrameTiming` telemetry for vertical sessions, recording build/raster/total span, vsync interval and delivered scroll/current/interaction context. It is diagnostic-only and is never read by geometry, navigation, Pipeline or schedulers.

## 0.31.0-dev.298 - Static presentation lifetime across upload-demand gaps

- The 10:01 dev.297 device Trace falsifies the subpixel/pixel-snap magnitude hypothesis: the visible jitter is much larger than 1-2px while actual vertical page layout remains stable. Roll back dev.297 `PhysicalPixelAlignedPresentation`, the external-texture marker, and the <=0.5px bounded-fill behavior; retain dev.296 physical sourceCanvas aspect authority.
- After initial static presentation, the same frame 0 is repeatedly presented again as `platformResidentReuse=true` when a page re-enters transition/upload demand (for example one identity presents 10 times). `PipelinePageOutputStream._present()` already skips the same identity/frame unless its projection was rebound; the existing `_bind(null)` cleared the UI surface, so upload eligibility was incorrectly controlling presentation lifetime and could replace an already visible page with the loading indicator before zero-copy reattachment.
- Decouple those lifetimes: an authoritative static surface may survive a temporary upload-demand gap only while the same `DecodeId` remains in the existing decode plan and the page still has a presentation listener. No upload/present work is created by retention; leaving the decode window, changing identity/generation, disposing output, or losing the last listener releases the projection. Encoded 3/7, decode 2/1, NetLane, upload policy, host keepAlive and physical texture retention remain unchanged.

## 0.31.0-dev.297 - Stitched external-texture physical-pixel alignment

- The 09:30 dev.296 device Trace keeps the already-frozen owners stable: 8/8 dimensions resolve from physical sourceCanvas, all 418 actual page-layout samples keep zero extent delta and identity scale/shear with one constant residual, and all 92 active vertical policy decisions keep `staticWarmUploads=0`. 19/24 platform presentations are zero-copy resident reuse.
- The remaining compositor fact is now explicit: every sampled stitched page width/height is integral in physical pixels, but 414/418 page global-top samples land on a fractional physical-pixel phase (about -0.49..+0.49px) because continuous scroll translation itself is subpixel. External Texture layers can therefore have independently sampled edges even though the Sliver boxes are stable.
- Keep ScrollPosition, ScrollPhysics and Reader extents untouched. For `fitWidth` media, only absorb the Reader source-aspect rounding residual when it is <=0.5 physical pixel; a real parent-aspect mismatch still uses the dev.293 FittedBox boundary. For Android/external-texture surfaces only, add paint-time vertical physical-pixel snapping when the presentation box itself is physical-pixel integral and has identity scale/shear. Encoded 3/7, decode 2/1, NetLane, retention and resident reuse remain frozen.

## 0.31.0-dev.296 - Source-canvas presentation aspect authority

- The 08:43 dev.295 device Trace closes the previous hidden-static-upload and Sliver-layout hypotheses: all 89 active vertical policy decisions keep `staticWarmUploads=0`; all 320 `pageLayoutSnapshot` events keep `extentDeltaPx=0`, identity 2x2 transform and a constant corrected layout residual.
- A smaller presentation-only dual authority remains visible in the same Trace: Reader item geometry uses physical source canvas, while LocalImagePlayer previously used decoded-raster dimensions. Page14 is source 960x1950 versus decoded 952x1936, about 0.116% aspect difference or 2.55 physical pixels of fitWidth height at 1080px width.
- Project physical `sourceCanvasWidth/sourceCanvasHeight` through `PipelinePageStreamSnapshot` and make them authoritative for LocalImagePlayer presentation aspect. Decoded raster remains only the pixel carrier. Do not change Reader geometry, fitWidth, encoded 3/7, decode 2/1, NetLane, texture resident reuse or retention.

## 0.31.0-dev.295 - Vertical active hidden-static upload deferral

- Fresh dev.294 device Trace separates the remaining fixed-region/scroll jitter from Sliver item geometry: all 333 `pageLayoutSnapshot` events keep actual render extent equal to expected extent (`extentDeltaPx=0`) and the sampled 2x2 transform remains identity. The dev.294 residual probe itself captured pre-frame scroll pixels and is corrected to compare the post-frame RenderBox against live scroll pixels.
- The same Trace exposes expensive Android texture presentation for static pages that are still hidden speculative `next` work during active vertical scrolling: page11 presents in about 24.4 ms (about 17.8 ms blit) and page10 in about 14.8 ms (about 10.7 ms blit). This is the gap left by dev.281, which deferred hidden `next2` only.
- During vertical dragging/scrolling/settling, defer static UploadDemand for every hidden speculative role while keeping decode warm. Current, transition and genuinely viewport-visible static pages still upload immediately; idle resumes the existing stable-role static warming. Encoded 3/7, decode 2/1, NetLane, retention, media-aspect and source/replay ownership remain unchanged.

## 0.31.0-dev.294 - Vertical jitter actual-layout observability

- Correct the dev.293 handoff premise using the authoritative device outcome: the vertical media scale/aspect defect is closed after dev.293; the remaining reproduced problem is fixed-region/scroll jitter. Keep the dev.293 `FittedBox(fitWidth)` boundary and freeze sourceCanvas, resident replay, previous3/next7, decode previous1/next2, NetLane and promoted-retention policy.
- Add low-frequency `pageLayoutSnapshot` telemetry for real visible vertical RenderBoxes. Scroll start/end are sampled explicitly and active scroll is capped to roughly 10 Hz; each sample correlates page identity/role/interaction with expected geometry, actual constraints/size/paint/global rect and transform so the next device Trace can distinguish Sliver layout movement from a stable box with downstream texture/compositor jitter.
- The probe is observation-only: it does not alter item extent, anchor, target selection, texture presentation, upload/decode/download admission or cache/retention. If actual boxes remain stable while jitter reproduces, the next layer is current/transition output projection and external-texture/SurfaceProducer compositor timing, not another geometry or media-aspect workaround.

## 0.31.0-dev.293 - Vertical media aspect independence

- 05:01 dev.292 device Trace closes the predecode/source-metadata hypothesis for the reproduced scale defect: pages 18-22 resolve `physical-ingress-source-canvas` roughly 0.9-5.5 seconds before first current, and source-canvas vs decoded-raster aspect error is only about 0.00-0.03%, yet active-scroll scale remains abnormal. Keep previous1/next2 decode and previous3/next7 encoded windows frozen.
- Supersede the old stitched shortcut that converted `MediaAspectViewport(fitWidth)` into `BoxFit.fill`. Reader continues to own item extent/navigation geometry, while media presentation independently preserves source aspect with top-aligned `FittedBox(fitWidth)`; a transient parent-extent mismatch may clip/blank only at the trailing edge, but may never stretch the image until idle.
- Do not restore dev.286 `presentationExtentAt`/OverflowBox or add another geometry owner. Preserve dev.291/292 physical ingress/replay authority and all Pipeline/NetLane/texture/retention policy windows.

## 0.31.0-dev.292 - Resident replay service binding boundary

- Fix the dev.291 local Dart compile failures caused by mixing the unbound `(DownloadSession, endExclusive)` resident replay service with the already-bound `(endExclusive)` physical-generation capability; DownloadSession now consumes only the bound callback and PipelinePageStream binds exactly once to its currently resolved physical session.
- Consolidate the canonical replay callback types in sessions and remove duplicate registry/downloads typedefs. Move artifact-cache/local immutable resident replay backend selection out of PipelineReaderSession into CompositionDownloadTransferRuntime; Pipeline now supplies only dynamic local-read priority.
- Preserve dev.291 physical-ingress source metadata/sourceCanvas authority and all Reader/decode/NetLane/texture/retention windows. The next local Dart/Flutter build remains authoritative for compiler closure.

## 0.31.0-dev.291 - Physical ingress source metadata authority

- 03:30 dev.290 device Trace shows all 12 `pageDimensionsResolved` events still use `basis=decodedRaster / source=decode-raster-fallback`; source-canvas resolution never hits despite future-page geometry commonly being prepared well before current, so do not widen decode previous1/next2.
- Fix the ownership error behind that miss: artifact-cache resident physical sessions intentionally do not duplicate immutable body bytes into `DownloadSession.artifact`, yet both Pipeline dimension resolution and `PipelinePageStream.readPrefix()` read that non-authoritative Artifact and silently lost source metadata.
- Retain only a generation-local 64-byte source-metadata prefix inside `DownloadSession`, parse WebP source canvas there, expose it read-only through `DownloadSnapshot`/`readIngressPrefix()`, and make Pipeline/UI projections consume that physical ingress fact instead of selecting a storage backend. Encoded body ownership and all Reader/Pipeline windows remain unchanged.
- Keep dev.290 source-canvas-over-raster semantics but supersede its direct `download.artifact.readPrefix(64)` implementation. The next device Trace must first prove `physical-ingress-source-canvas` is reached before any further scale hypothesis is promoted.

## 0.31.0-dev.290 - Source-canvas geometry authority

- 02:30 dev.289 device Trace falsifies predecode-window insufficiency for the reproduced scale defect: imminent page dimensions/geometry are already prepared roughly 0.4–3 seconds before visibility/current, so keep previous1/next2 decode and previous3/next7 encoded windows frozen.
- Refine dev.287 dimension semantics: decoded frame width/height describe the aligned/downsampled presentation raster, not final page geometry. Pipeline now prefers PageAsset/source WebP canvas metadata and marks dimensions as `sourceCanvas`; decoded raster is provisional fallback only and cannot overwrite source authority.
- Fix `parseWebpPrefixInfo()` so VP8/VP8L/VP8X canvas headers can be read before the declared compressed image chunk is complete. `LocalImagePlayer` no longer leaks non-authoritative output-surface raster dimensions into Reader geometry.
- Keep dev.289 Pipeline frame/notifier boundaries and all Reader/NetLane/decode/upload/texture/retention policy windows unchanged.

## 0.31.0-dev.289 - Pipeline frame scheduler boundary

- Fix the dev.288 local Dart compile failure where the `pipeline_page_output.dart` part still referenced `WidgetsBinding` after its parent session library stopped importing Flutter widgets; treat it as a hidden framework-owner leak rather than adding another parent import.
- Add Pipeline-owned `PipelineFrameScheduler`; output visual-claim retirement and transfer-progress frame coalescing consume that capability, while the Flutter `SchedulerBinding` adapter lives only in `pipeline_native` presentation composition.
- Replace transfer-progress `ValueNotifier` with read-only `PipelineTransferProgressFeed`; ReaderRuntime subscribes through its own Stateful presentation adapter. Keep the existing progress semantics and visual-swap claim lifetime.
- Constrain direct Flutter imports under `pipeline_runtime/lib/src` to the three explicit adapter seams: opaque Widget surface ABI, Reader session host, and root asset-bundle transport. dev.287/288 dimension projection and all Reader/download scheduling policies are unchanged.

## 0.31.0-dev.288 - Pipeline dimension projection boundary

- Fix the dev.287 local Dart compile failure where `PipelineReaderSession.pageDimensions` exposed `ValueListenable` without importing its Flutter foundation declaration; do not paper over it with another UI import.
- Replace the temporary `ValueNotifier`/`ValueListenable` dimension surface with a Pipeline-owned read-only `PipelinePageDimensionsFeed`. Retained facts replay to newly attached Reader consumers, while publish/clear remain library-private and the boundary carries `pageIndex + assetKey + width/height` directly.
- Remove Flutter imports from `pipeline_reader_session.dart`, move `rootBundle` knowledge behind `AssetBundleTransport.root()`, and pre-index chapter `pageId -> pageIndex` once so source-kind, decode-dimension and animation facts share one identity resolver instead of rescanning the chapter independently.
- ReaderRuntime consumes dimension events directly through its existing `_reportPageDimensions` owner; it no longer pulls a notifier map and rescans every chapter page after each decode fact. dev.287 decode-ahead/future-tail geometry policy itself is unchanged.

## 0.31.0-dev.287 - Decode-ahead vertical geometry preparation

- Supersede dev.286 live-presentation compensation after device evidence showed the ratio fact already existed in decode hundreds of milliseconds before UI/output, while Reader geometry learned it only after the page entered the viewport.
- Publish first decoded frame dimensions as read-only Pipeline page metadata and replay them through ReaderRuntime’s existing aspect-ratio owner.
- During active vertical scroll, prepare only pages strictly beyond the real visible tail; prefix-affecting ratios still wait for idle layout-time correction. Remove `presentationExtentAt`/OverflowBox workaround.

## 0.31.0-dev.286 - Live aspect projection over frozen vertical layout

- 00:09 dev.285 device Trace shows a new presentation regression rather than another download/texture failure: 16 of 20 page first-frame dimensions arrive while the vertical Reader is dragging/scrolling. Their measured height/width median is about 3.20 while unknown vertical geometry falls back to 1.5, so dev.280's scroll-stable layout snapshot can remain intentionally stale by more than 100% until idle.
- `MediaAspectViewport(BoxFit.fitWidth)` deliberately fills the Reader-owned page box because exact vertical geometry normally owns aspect ratio. Combined with the stale active-scroll snapshot this stretched newly decoded media to the placeholder/old extent until pending ratios committed at idle.
- Keep the dev.280 invariant that `ListView.itemExtentBuilder` is immutable during one active scroll, but split layout extent from visual presentation extent. `ReaderVerticalGeometry.presentationExtentAt()` projects the latest measured ratio without mutating the snapshot; the vertical page renders in a top-aligned overflow box at that live aspect-preserving extent and transiently clips only the portion outside the frozen sliver box. Idle still performs the existing atomic geometry correction.
- Remove the stale stable-spec reference to the device-falsified dev.284 mount-travel keep-alive guard. No Reader resource window, Pipeline demand, Download/Decode/Upload, texture, NetLane or promoted-retention policy changes.

## 0.31.0-dev.285 - Bounded hot promoted physical retention

- 16:22 dev.284 device Trace falsified the page-host composition-boundary hypothesis: the new composition guard removed the prior page18/page19 short mount/dispose churn, but the fixed-region jitter remained. Roll back the dev.284 mount-travel keep-alive behavior and mark ADR 0263 superseded.
- The same Trace shows 84 `retired-promoted-resident` events in ~41.7s, including repeated five-session retirement bursts at window boundaries. Reversing across those boundaries recreates the same promoted physical pages from persistent artifacts through `artifact-cache-stream` / `consumer=session-copy`, matching the repeated full session-copy risk already recorded by the dev.269 audit.
- `PhysicalTransferRetention` now keeps a composition-owned LRU tail of at most 8 idle promoted immutable physical sessions. Only pressure victims retire, after the existing ordinary artifact handoff succeeds; unfinished partial retention remains the separate 32-session / 256 MiB policy. This retains physical/source-generation authority, not Reader demand, NetLane response capacity or a second artifact-body cache.
- Retention Trace keeps the historical `retired-promoted-resident` / `retired-promoted-durable` actions and adds `reason=hot-promoted-retention-pressure`, `maxIdlePromotedSessions` and `retainedIdlePromotedSessions`.

## 0.31.0-dev.284 - Vertical composition cache-boundary retention

- 15:33 dev.283 Trace将固定位置双向抖动定位到ListView cache-edge page-host churn：page18/19在page10/11附近出现0.25~1.88s的短命mount/dispose，且均未形成first frame；dev.283 hidden-target违规已为0。
- 保留nominal纵向page-host current±7 keepAlive，但新组成host在Reader current尚未离其mount point超过2页时继续AutomaticKeepAlive，避免sliver layout先于ScrollNotification current更新造成的边界反复销毁/重建；不是timer grace，也不移动cacheExtent。
- `pageHostMounted/pageHostDisposed`增加`compositionGuardActive`，便于设备直接确认guard吸收cache边缘churn；Pipeline 3/7、decode/upload、geometry/anchor和texture resident reuse均不变。

## 0.31.0-dev.283 - Vertical visible-target authority

- 14:52 dev.282 device Trace exposed a direction-asymmetric Reader observation bug: while scrolling toward previous pages, 22 samples had `velocity < 0` and only the current page visible but still reported `targetIndex=current+1`; the corresponding next-direction pattern appeared 10 times. `ReaderVerticalGeometry.positionAt()` reports `index + page-local fraction`, not PageView interpolation, so the generic floor/ceil target fallback systematically biased hidden targets toward higher indexes.
- Vertical observations now disable logical-position target inference. Their target is owned only by real viewport coverage: an actually visible outgoing page may remain transition-owned, an actually visible incoming page may become transition, and a viewport containing only current reports no target. Horizontal/PageView inference is unchanged.
- dev.280/281 geometry correction and dev.282 resident texture reuse remain intact because the new Trace confirms their intended behavior; no prefetch window, waterline, texture, NetLane, Venera or cache-capacity change is made.

## 0.31.0-dev.282 - Retained Android texture resident presentation

- 14:02 dev.281 真机Trace确认slow-release geometry错页已经闭合、vertical active `staticWarmUploads=0`真实生效；剩余ballistic抖动包含retained静态OutputFrame的重复platform present，presentation ordinal 1–3仍可产生约15–37ms Surface blit/channel round-trip。
- Android texture lease现在按具体OutputFrame对象identity记录当前SurfaceProducer resident frame；同一resident frame重复present直接返回`platformResidentReuse=true`零copy telemetry，不再再次retain/blit/schedule。不同OutputFrame、resize、release或更新的async presentation revision会使resident identity失效；较旧async tail不得覆盖较新的resident owner。
- SurfaceProducer cleanup/recreate仍由既有Kotlin `onSurfaceAvailable -> redraw()`持有，Reader/Pipeline不接管platform surface生命周期；dev.281的hidden next2 active-scroll upload deferral、decode window与geometry correction继续冻结。

## 0.31.0-dev.281：纵向 idle layout correction + active next2 texture deferral

- 修复dev.279遗留Dart编译错误：`_SourceWatchBinding.session`为mutable generation pointer，constructor不得继续`const`；新增gate直接禁止该非法组合。
- 13:14 dev.280 Trace确认慢拖松手的抖/错图来自idle ratio commit两阶段窗口：10.432s page18进入idle后约6.7ms无反向用户输入却变成page17。ratio提交现把top-pixel target交给纵向ScrollPhysics，以layout-time correction在新content dimensions建立的同一次layout中通过ScrollPosition correction原子修正offset，不再随后`jumpTo`制造scroll notification。
- 同一Trace的快速ballistic logicalPosition保持单调，但15.502s/15.906s两个非可见`next2` static startup texture分别出现约15.2ms/21.9ms platform upload。vertical dragging/scrolling/settling期间仅defer非可见next2静态UploadDemand；next2 decode、immediate next、current/transition和真实可见页保持。idle后next2 texture warming恢复。

## 0.31.0-dev.280：纵向滚动稳定 geometry snapshot

- 12:24 dev.279 Trace复核通过上一阶段：本地same-exact re-entry记录13次`sealed-source-generation-preserved`且invalidated upload/decode均为0；冷启动网络Reader已出现18次`local-hydration-ready committedLength>0`，current page234约328ms首帧，page139从262,800-byte durable prefix起步约125ms首帧。dev.279 generation/partial阶段暂时收口。
- 纵向滑动抖动并非dev.207 ratio-driven主动anchor `jumpTo`复发：Trace logicalPosition在连续scroll段总体单调。剩余竞态是异步`pageAspectRatios`在drag/ballistic期间立即重算`ReaderVerticalGeometry`与`ListView.itemExtentBuilder`，使sliver item extent在active scroll中改变并触发布局/scroll correction。
- ReaderView新增scroll-stable `_verticalLayoutRatios` snapshot：dragging/scrolling/settling/scrubbing期间ratio latest-wins暂存，ScrollEnd真正idle后一次性提交，并只在该idle commit边界使用top-pixel anchor补偿真实extent变化。viewport/DPR/stitch/显式navigation既有语义不变；不改Pipeline、FrameBudget、NetLane、Venera、partial或generation生命周期。

## 0.31.0-dev.279：sealed Reader generation continuity + lifecycle partial checkpoint

- 09:37 dev.278 Trace确认本地二次进入存在退化：page5首次约304ms，二次/三次约366/357ms，但更关键的是每次re-entry都对约11个same-exact本地source触发`physical-generation-changed`，current及热邻页decode/upload被机械失效重建。dev.277把不同DownloadSession object无条件等同Reader encoded generation过宽。现仅对`sealed + sourceReady + no failure`且无pending synchronized attachment的same-exact projection保留Reader encoded generation；mutable/incomplete source仍严格换代。old same-id teardown增加concrete identity guard。
- 同一Trace冷启动已恢复`persistentMappings=5`却对current/邻页全部`local-hydration-miss committedLength=0`，current约6.14s后重新从origin得到首帧。根因是未达到32-session/256MiB retention压力的hot partial仅在ephemeral workspace，进程退出不保证异步final dispose完成。composition runtime新增`checkpointPartials()`；App paused/detached只发lifecycle signal，durable写入仍由`PartialDownloadHandoff`拥有，close会join正在进行的checkpoint。
- 不改NetLane、Venera、缓存容量、previous3/next7、body5/3/2/1、decode2/1、holder7/5/3/2或normal5+current reserved1。

## 0.31.0-dev.278：Reader re-entry UploadRegistry decode-generation binding 闭合

- 08:31 真机 Trace 再次稳定复现本地图片回访失败：第一次进入约208ms得到首帧；第二次进入发生`physical-generation-changed`且`invalidatedUploads=1 / invalidatedDecodes=1`，artifact重新提供5,906,374 bytes，replacement decode最终达到depth=7，但upload始终停留`waitingFrame`，没有进入`uploading/frameUploaded`；第三次进入重复同型失败。因此dev.277的old uploader delayed-release不是剩余主因，阻塞发生在platform upload之前。
- `UploadRegistry.get()`现在把“logical DecodeId相同”和“concrete DecodeSession generation相同”分开：每次取得当前DecodeRegistry session并校验缓存UploadSession绑定对象；若对象identity不同，先dispose旧UploadSession，再创建绑定当前DecodeSession的replacement。UploadSession自身仍禁止跨代动态换绑，`LiveCoordinator`既有upload→decode invalidation顺序保持。
- 新增回归覆盖DecodeRegistry独立替换concrete generation后UploadRegistry必须退休旧binding；不修改previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1、Venera或缓存容量。

## 0.31.0-dev.277：Reader re-entry / ingress generation 生命周期闭合

- 07:54 Trace确认本地图片第二次进入Reader时artifact完整且decode depth已到7，但新generation反复`uploadStarted`无`frameUploaded`；根因是旧UploadSession pending prepare可在dispose后延迟`release(DecodeId)`，跨代退休新generation uploader slot。generation dispose现立即release并禁止old async tail二次release，ordinary detach deferred-release保持。
- `DownloadIngressProjectionRegistry.get(session)`修为generation-aware attach；same DownloadId的新DownloadSession不得继承旧Reader-local source。synchronized replay只有projection自身epoch/length/sealed/failure与稳定physical boundary一致后才能加入live fan-out。
- Artifact partial→final promotion的rename窗口由storage owner内部隐藏：readBytes/readChunks/readPrefix按preferred/alternate路径直接open同一authoritative data file，避免rename后state切换前被Reader误判为0字节。previous3/next7、5/3/2/1、5+1与Venera策略不变。

## 0.31.0-dev.276：Venera current handoff gate priority 闭环

- 05:37 dev.275 Trace中resolver warm态仍稳定为3 cache hit+1 page-specific origin，但`sourcePlanGateWaitMicros`中位约669ms、最坏约3.89s；cold current仍会被单Venera invocation context中的旧viewport工作阻塞。
- runtime gate此前只在waiter入队/升priority时重做preemption；active invocation从current=1000降级后不会重新比较已等待的新current。现监听active `PriorityObservableTaskControl`，仅在active跨出current阈值且已有current-class waiter时，重用既有40-point规则请求取消旧invocation。
- 保持`maxConcurrentInvocations=1`、single physical permit、dev.275 host resolver cache、NetLane 5+1、3/7与5/3/2/1不变；普通820→700/previous780 viewport jitter仍不触发破坏性plan preemption。

## 0.31.0-dev.275：Venera resolver network cache owner 收口

- 04:42 Trace确认dev.274 current/local→network rank已闭合；request-plan cache hit近乎零成本，而cold miss仍有明显长尾，初始current可出现4/4 bridge resolver origin，warm后多数为3 hit+1 page-specific origin。
- source-requested `cache-time`从单`VeneraNativeBridge`私有cache迁到`NativeExternalPluginDriverHost`唯一`VeneraHttpCacheStore`；按`pluginId/pluginVersion/sourceKey`分区，bridge replacement不再机械清空long cache，host最终close统一清理。
- 保留10MiB/1MiB边界、Cookie/request-header identity、约5秒/6小时TTL及Venera JS单invocation；不预解析整章、不增加runtime并发、不修改partial/NetLane/current参数。

## 0.31.0-dev.274：编译闭包与 local→network priority continuity

- 修复dev.273 `Validators.isNotEmpty`编译错误：按transport真实契约使用`Validators.canResume`判断是否存在可续传validator。
- 04:00 Trace确认pre-NetLane local prepare把network task创建顺序泄漏给local I/O完成时序：current=1000最先demand却第四个`downloadStarted`。local prepare完成现进入composition physical-owner admission arbiter；lower ready work在higher demanded local prepare结束前不得越过，随后仍由NetLane唯一负责容量/preemption。
- 不改变Venera JS单invocation、previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1。

## 0.31.0-dev.273：durable partial read owner 解耦

- 03:33 dev.272 Trace中58次network local prepare均为`committedLength=0` miss，中位约87ms/最大约125ms；origin均有4个verified-equivalent candidates。
- `PersistentDownloadArtifactStore.openPartialDownload`改为SQLite index/file直接authority，cold partial hit/miss不再materialize synthetic durable-store `DownloadSession`；resume metadata仅提供validators/length加速证据，明确wrong owner才使record失效。
- partial write mutation、dev.272 pre-NetLane local prepare与共享`ArtifactCacheReadScheduler`保持；无local bytes trace改为`local-hydration-miss`。3/7、5/3/2/1、5+1与current不变。

## 0.31.0-dev.271：transport/source lease 与 body-read permit 解耦

- 01:26 dev.270真机Trace确认连接阶段回归：source-loader open中位约1.60s/P90约3.42s，origin request-plan中位约1.02s；同时`globalRunning`达到17–20且观测origin均为HTTP/1.1。dev.268把normal5只保留为body-read permit后，parked live response虽不读body却仍占真实source/socket，实际transport并发绕过5路。
- NetLane新增独立`transportLeases`资源：live source response park只释放body-read permit而继续占transport lease；durable artifact local body同时释放两者。normal5+current reserved1同时界定transport/source lease与body-read permit，`globalRunning`仅表示physical task数。
- 删除独立`maxInactiveParkedResponses`容量owner。新的normal transport pressure只可typed回收`demanded=false` inactive parked lease（`inactive-transport-lease-reclaim`）；仍有demand的parked response不成为normal victim。current 1000、reserved1、restart-cost rank、3/7、5/3/2/1均不变。

## 0.31.0-dev.272

- 将cold partial/artifact local physical prepare从NetLane transport admission前移：`DownloadTransferOwner`按physical session generation single-flight hydrate，Reader-local ingress可在网络lease可用前消费prefix；cold partial durable read复用既有`ArtifactCacheReadScheduler`分块/动态priority调度，prepare完成且仍需provider时才创建NetLane task。
- local prepare失败不再把durable acceleration变成network blocker：每个physical generation只尝试一次local hydration，失败记录后降级provider fallback；同步demand planning、3/7、5/3/2/1、normal5+current reserved1均不变。

## 0.31.0-dev.270：current body-read preemption 与 inactive retention eviction 事务解耦

- 00:22 dev.269 真机 Trace 中 11 次 `downloadPreempted` 全为 `inactive-response-retention-eviction`，真正 `high-priority` current preemption 为 0。源码审计确认 inactive parked response 淘汰仍复用 `cancelForPreemption/TaskPreemptionSnapshot`，导致不占 read permit 的后台 response eviction 也占用 `_hasPreemptionInFlight`，可阻塞 current 对 body-read permit 的抢占。
- 新增独立 `TaskRetentionEvictionSnapshot/cancelForRetentionEviction`；current body-read preemption 与 inactive response eviction 各自 single-flight，后台 eviction 不再阻塞 current。blocked live-current response reacquire 优先于新 high-priority pending 的破坏性 admission。
- Trace 将 retention eviction 从 `downloadPreempted` 拆为 `downloadEvicted`；`downloadPreempted` 重新只表示真实 scheduler priority preemption。previous3/next7、5/3/2/1、normal5+current reserved1、restart-cost victim rank 均未改变。

## 0.31.0-dev.269：demanded parking / inactive response retention / artifact read owner 解耦

- 23:32 dev.268 真机 Trace 中40次 park→resume 均保持同 response，但17次 `parked-response-eviction` 有9次 victim 仍 `demanded=true`。根因是 dev.268 用一个 `maxParkedResponses=10` 同时管理“仍有consumer的flow pause”和“无consumer的inactive retention”，把已经解耦的body-read permit再次通过全局parked上限耦合回response lifetime。
- NetLane 现在只对 `demanded=false` 且确实保留live network response的 parked task实施 `maxInactiveParkedResponses`；demanded flow-paused response不消耗inactive retention预算，也绝不是retention eviction victim。Reader profile删除`parkedResponseCapacity`，3/7不再拥有socket/response容量策略。
- `releaseResponseReadPermit(responseRetained: ...)` 显式区分“保留live response的pause”与“task继续但已切换到非network body”。durable artifact-cache body确认authority后以`responseRetained=false`释放NetLane permit，本地9–18MiB replay只受既有`ArtifactCacheReadScheduler`调度，不再双重占remote NetLane 5路。
- Trace拆分 `globalReadPermitReleasedTasks / globalDemandedParkedResponses / globalInactiveParkedResponses / globalInactiveParkedLimit`；真实inactive淘汰改名`inactive-response-retention-eviction`。不提高parked数量、不增加Reader距离/Range例外。

## 0.31.0-dev.268：live response parking 与 body-read permit 解耦

- 14:54 dev.267 真机 Trace 证明 `demanded=false` 的 active task 虽不再因 3/7 detach 直接取消，但随后 normal capacity 的 `inactive-reclaim` 仍通过同一个 `CancelToken` 销毁 rhttp response；同时 Range-capable 页的 `pseudo-suspended` 仍会在窗口内主动 `iterator.cancel()`。因此 dev.260–267 的 `pseudo-retained / pseudo-suspended / inactive-reclaim` 仍把“保留response”和“占5路读取额度”绑定在同一 NetLane active slot。
- 重构 NetLane 资源模型：`active` 只表示持有 body-read permit 的任务；`running` 表示仍存活的 physical task/response；达到 flow credit 或暂时失去 consumer demand 的 DownloadJob 释放 read permit 但保留同一 `StreamIterator` 与 response，恢复时同一 task 重新竞争 read permit，不创建第二个 transport attempt。Reader 默认 parked-response 上限10；超过该有界池才允许显式 `parked-response-eviction`。
- 删除 production `DownloadFlowSuspended`、`pseudo-suspended`、`pseudo-retained`、`retainFlowResponse` 与 dev.267 `inactive-reclaim`。physical structural frame proof 回归 `DownloadSession` generation owner；Range 能力只决定真正 response eviction 后如何恢复，不再决定达到水位时是否主动关闭 response。
- normal5 + current reserved1 现在是 **body-read permit** 上限，而不是 live response 数量上限。parked response 不申请下一块 body；HTTP/1.1 socket/native buffering 风险由 parked-response 有界池控制，不允许无界保留。

## 0.31.0-dev.267：working set 与 physical transfer lifetime 解耦重构

- 13:50 dev.266真机Trace再次证明dev.264–266仍在错误层次补偿：current 99→98仅反向一页，policy即从readDirection=+1切到-1，并在同revision连续detach page102–106五个download claim。调方向阈值只能推迟批量detach，无法解决“working-set变化为何能决定已admit physical transfer生死”的所有权错误。
- 回滚dev.264 cooperative flow-yield、dev.265 near-two保护与dev.266 weighted-trend方向实现作为生产基础；保留dev.263与网络无关的Decode→Upload generation修复、dev.262 typed no-Range response continuity。历史ADR/audit保留并标记Superseded。
- 参考只读VibeVenera `StreamingDownloadTask.retainWhenInactive=true` / scheduler语义，将physical task显式增加scheduler-owned `demanded`状态：queued且无claim仍可撤销；already-admitted active最后claim消失只降priority=0并标记demanded=false，不因3/7 membership变化直接cancel。
- NetLane只有在真实normal/bucket容量被新的demanded pending work阻塞时，才可统一回收一个demanded=false active task；demanded=true active task不受normal reclaim。回收仍走既有single-flight cancellation并等待victim物理退出后释放permit，trace记录`preemptionReason=inactive-reclaim`。不再由Range、flowTarget、next2/previous3或Reader距离决定谁可让槽。
- 浏览方向保留为纯Pipeline工作集事实但简化为连续两次committed反向页变更才确认；单次反向、scrub/jump/abs(delta)>5不切向。RoleWindow/rank/5/3/2/1消费同一readDirection，但该方向绝不拥有transport cancellation。
- 冻结previous3/next7、decode2/1、body5/3/2/1、holder7/5/3/2、NetLane normal5+current reserved1；本轮不增加连接、grace、near flag、flow-yield flag或第二scheduler。

## 0.31.0-dev.266：Pipeline-owned 浏览方向与3/7工作集收口

- 12:49 dev.265真机Trace与`vibevenera-master.zip`只读对照确认，近几轮retention/yield补丁的共同上游缺口是Pipeline没有浏览方向事实：RoleResolver固定index +7/-3，far rank与5/3/2/1也各自按index符号解释方向。
- 新增有滞后的`BrowsingDirectionPredictor`：单次反向只形成candidate，连续2次反向或加权趋势才确认切向；scrub/jump/abs(delta)>5不学习。RoleResolver、download/static rank、animated flow credit统一消费同一`readDirection`。
- 删除dev.265 `protectFlowRetentionFromNormalYield`从DownloadDemand/TransferDemand/NetLane/CancelToken的整条复制链。冻结flow credit直接表达局部性：next2 target3不声明yieldable；outer shallow target<=2在no-Range且已满足时才可yield；immediate adjacent由`retainFlowResponse`继续保护。
- dev.262 no-Range continuity与dev.264 cooperative slot fairness保留，各自只处理transport capability/slot事实；NetLane不再承载Reader页距例外。7/3、2/1、5/3/2/1、holder7/5/3/2、normal5+current reserved1均不变。

## 0.31.0-dev.265：近二页 continuity hold 与 outer slot fairness 分层

- 12:25 dev.264 真机 Trace确认用户所见“只隔一页就被cancel”实际没有`downloadPreempted/cancelled`；发生的是dev.264 cooperative `pseudo-yielded`。current=270时page272仍是next2/target3却在8.167s被yield；current=267时page269是next2/priority800/target3，却在13.894s为了priority640的page264(previous3)让槽，page264随后13.911s才`downloadStarted`。
- 根因是dev.264把所有`!retainFlowResponse` no-Range satisfied hold都视为outer optional continuity，遗漏了next2/previous2虽不是immediate adjacent但仍属于高概率近二页。slot fairness因此可以反向牺牲近页去服务更远页。
- `DownloadDemand → TransferDemand → NetLane CancelToken`新增`protectFlowRetentionFromNormalYield`语义位，只保护与current物理距离<=2的near-two hold免受normal-pressure cooperative yield；`retainFlowResponse`仍只属于immediate next/previous，因此Range-capable next2/previous2仍可按原规则安全suspend，不会被新保护强制常驻连接。
- no-Range outer distance>=3在credit/playable floor满足后仍可按dev.264让槽；near-two迁到outer时同physical task原位撤销保护，outer迁回near-two时可撤销尚未执行的yield request。最后一个Reader claim消失时近页保护与adjacent retain都会清除，避免rank0 retained task携带陈旧near语义。
- previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、NetLane normal5+current reserved1全部不变。

## 0.31.0-dev.264：non-Range continuity hold 的 NetLane 槽公平性

- 11:45 dev.263 真机 Trace确认单向预下载失败不是3/7 demand缺失，而是dev.262引入的 non-Range response continuity 在body target已满足后仍长期占normal NetLane slot；逻辑previous2/previous3虽持续有660/640 demand，却会被另一侧已满足的no-Range hold饿死。
- `CancelToken`新增只属于NetLane调度的flow-retention状态：仅“non-adjacent + no-Range + body credit已满足”的continuity hold标记为yieldable；immediate next/previous显式warm retention、current以及尚未满足body credit的receiving均不可被normal pressure触碰。
- normal demand无slot时，NetLane最多请求一个yieldable hold协作`pseudo-yielded`；原task真实退出后才释放permit。该路径不调用cancel/preemption，partial/proof沿既有`DownloadFlowSuspended`闭包保留；Trace记录`yieldToPriority`。
- 不改previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、normal5+current reserved1，也不恢复dev.245之前的normal destructive preemption。

## 0.31.0-dev.263：physical-generation rebind 的 Decode/Upload 依赖闭包

- 11:13 dev.262 真机 Trace确认“部分图片打不开”不是网络或decode不足：page98/page97分别在25.192s/25.872s发生`physical-generation-changed`；page97新DecodeSession随后已在31.409s解到depth=7且source完整sealed，但同identity反复`uploadStarted`后始终没有`frameUploaded/firstFrameReady`。
- 根因是source-watch rebind只`DecodeRegistry.invalidateForDownload()`，而retained UploadSession构造时永久持有旧DecodeSession引用。新generation创建新DecodeSession后，旧UploadSession仍观察已dispose旧holder，因此永久`waitingFrame`。
- `UploadRegistry`新增按DownloadId的generation invalidation；rebind时先cancel decode/upload lane，再按upload→decode顺序失效依赖链。新frame-ready会按既有demand重新创建绑定新DecodeSession的UploadSession。trace新增`invalidatedUploads/invalidatedDecodes`。
- 扩展source-watch rebind regression覆盖“旧generation已decode+upload→退休→同logical新physical generation→再次decode+upload”，要求新UploadSession实例与第二次output。网络窗口、水位和dev.262 non-range flow策略不变。

## 0.31.0-dev.262：无可靠 Range resume 的 bounded-flow response 连续性

- 09:59 真机 Trace确认dev.260/261的 immediate warm-response metadata闭包本身成立，但3/7内仍有另一条必现重开路径：page102作为next2在452,600 bytes/target3达到水位后于9.253s被`pseudo-suspended`；current从100→101后它成为next1，10.173s重新`downloadStarted`。Range probe返回HTTP 200，随后`full-body-prefix-catchup`明确记录`duplicatePrefixBytes=452600`。用户反向切页后，同一page102在751,900 bytes又因next1→next2被再次`pseudo-suspended`。
- 根因不是partial丢失、5路驱逐或`retainFlowResponse`传递失败，而是consumer-paced bounded flow把“正frame credit满足”无条件解释为“远端response可关闭”；这只在该response已正面证明`rangeSupported=true`时才可安全成立。对未正面证明Range resume的response，关闭后下一次角色晋升只能从0/full-body prefix catch-up，形成真实重复网络字节。
- `DownloadJob`的flow gate现接收`ByteResponse.rangeSupported`这一typed transport capability：immediate next/previous仍按既有`retainFlowResponse`保活；除此之外，`consumerPacing && !rangeSupported`的已admit response也保持同一physical task，以既有最多100ms一chunk的`pseudo-retained`节奏等待credit/foreground变化。只有正面Range-resumable且非adjacent的response继续在满足5/3/2/1后`pseudo-suspended`。真实NetLane pressure/preemption/cancellation仍可结束任何active attempt。
- 新trace字段在flow-control事件中记录`responseRangeSupported`；non-range capability retention额外记录`retentionReason=range-resume-unproven`。这不从diagnostics反推policy，policy直接读取typed `ByteResponse.rangeSupported`。3/7、5/3/2/1、decode 2/1、holder 7/5/3/2、NetLane normal5+current reserved1均未改变，也未恢复全窗口full-body drain。

## 0.31.0-dev.261：NetLane pending metadata 构造闭包

- 用户本地编译确认dev.260存在公共调度元数据迁移未闭合：`_Pending.retainFlowResponse`已改为required，但`_Lane.replace()`与`_Lane.follow()`仍直接构造`_Pending`且漏传该字段，导致Dart编译失败；warm-response策略本身不变。
- `_Pending`创建现统一收口到`_Lane._createPending()`：submit/replace/follow不再各自复制构造字段；generic replace/follow显式继承唯一默认`flowTargetFrames=0 / retainFlowResponse=false`，Reader ranked submit仍传入真实flow metadata。
- 既有replace/follow Dart测试补充CancelToken默认flow metadata断言，并新增dev.261静态gate要求production只有一个`_Pending`实例化点，防止以后新增required task metadata再次遗漏旁路构造。3/7、5/3/2/1、warm adjacent response、NetLane 5+1全部冻结。

## 0.31.0-dev.260：相邻页 warm response 与 bounded flow 解耦

- 09:00 真机 Trace确认 dev.259 已激活5/3/2/1，但暴露 dev.254 consumerPacing suspension 的直接回归：page99 作为 next1 在491,520 bytes/target5于8.840s主动 `pseudo-suspended`，约99ms后成为current，8.944s即从同一partial重新 `downloadStarted`。这不是5路NetLane挤掉连接，而是bounded flow满足后主动关闭了最可能马上切入的相邻response。
- `DownloadDemand/TransferDemand/NetLane CancelToken`新增单一 `retainFlowResponse` policy bit，只对 immediate `next/previous` 为true；current/transition仍target0 unlimited，next2/near/far仍在水位满足后真正suspend。
- `consumerPacing`达到frame/playable credit后，warm adjacent response进入 `pseudo-retained`：保持同一response/task并最多每100ms放行一个chunk；角色升为current/transition时同token target0直接 `pseudo-resumed`，不得产生第二次 `downloadStarted`。角色远离时retain bit原地撤销，下一次blocked立即 `pseudo-suspended`并只保留partial。
- 3/7、5/3/2/1、NetLane normal5+current reserved1、physical partial/frame proof/playable floor、provider/source/decode ownership均不改变；partial retention仍独立于连接数。

## 0.31.0-dev.259：runtime WebP cost 与 Reader partial playable join 解耦

- 08:03真机Trace纠正dev.258的主因判断：59/59次`policyDecision`均`animatedFlowActive=false`且3/7全部`flowTargetFrames=0`，整场没有`mediaClassified`。opaque `venera-resource:`没有manifest WebP hint，而runtime animation classification又等待`AnimationInfo.complete`，形成“未分类→不限流→前5页占满normal network→远端无连接→更难完成分类”的循环。跳页后旧窗口receiving task还以rank0 retained-background占槽，新current才用reserved slot/preemption开连接。
- physical/Reader ingress一旦实际sniff到`ContentKind.webp`，现仅把该事实投影为Pipeline transport-cost evidence并立即启用既有5/3/2/1 bounded body flow；它不等于`animated=true`，DecodeSession的authoritative static/animated classification仍优先并可恢复静态full 3/7。3/7、frame target与NetLane 5+1均不改。
- 新Reader late-join已有nonresident WebP partial时，不再先本地重放整个committed partial才发布decode source；先按同一decoder prefix contract重放并发布最小playable/required/unresolved prefix，让current立即开始decode，再在同一Reader-local native source上追平剩余authoritative suffix，稳定后才加入physical live fan-out。physical partial availability、network need与Reader-local decode availability因此不再互相替代。

## 0.31.0-dev.258：decoder playable-prefix 与 transport structural frame 解耦

- 05:29真机Trace确认前几轮partial/cancel/generation/proof修复均成立，但暴露真正的相邻页预下载根因：`WebpFramePrefixTracker.completedFrames`只统计完整ANMF结构块，却被直接当成“可播放帧”授权suspension。page206在205,860 bytes时因`completedFrames=2`被`flow-satisfied(target=2)`停止，而DecodeSession已明确frame0仍需262,144 bytes；切成current后必须重开response/full-body catch-up，首帧仍约2.45s。对照page207在245,760 bytes已真实解出前2帧，切页首帧约112ms。
- DecodeSession现在只输出decoder-owned prefix evidence：`decodedPrefixFrames / firstPlayablePrefixBytes / firstFrameRequiredSourceLength`；LiveCoordinator通过当前generation-aware source watch把只读evidence投影给physical DownloadSession，DecodeSession不重新持有physical/network owner。
- DownloadJob继续用ANMF计数表达encoded structural credit，但只有“structural target满足 + authoritative partial达到decoder playable-prefix floor”才允许pause/pseudo-suspend。unresolved floor复用`WebpDecodePrefixHints`唯一quantum contract；decoder后续need-more-data抬高floor时旧flow proof自动失效并从同partial继续。3/7、5/3/2/1、NetLane 5+1、provider与source-plan策略均不改。

## 0.31.0-dev.257：local completion 与 provider transport admission 解耦

- 04:58真机Trace确认dev.256 frame-prefix proof闭包成立：`downloadPreempted/Failure(cancelled)/download failure`继续为0，31次`downloadStarted`中不存在“已有proof N却以正target<=N重开”的样本。
- 但有3个physical identity已经完成`artifactPromoted`，后续新physical generation在local prepare恢复完整artifact后仍记录`downloadStarted`；三次开始时`committedLength`分别为16,005,312 / 13,452,574 / 9,775,218 bytes，且之后均无`sourceRead/bytesCommitted/receiving`，证明只是本地完成恢复误进入provider admission/telemetry。
- 抽取`DownloadJob.completeWithoutTransport`作为唯一local-completion primitive；`DownloadTransferOwner`在`prepareDownload`之后先调用该primitive，若session已promoted或完整partial可本地seal/promote，则记录`transfer-admission/local-completion-short-circuit`并返回，provider transport lookup/lease与`downloadStarted`均不得发生。provider claim也在prepare后重新解析，避免local prepare期间consumer换代后捕获旧provider。3/7、frame credit、NetLane与partial/source/decode不改。

## 0.31.0-dev.256：physical frame-prefix proof 与 flow target 解耦

- 04:31真机Trace中`downloadPreempted=0`、`Failure(cancelled)=0`、download/decode/source failure均为0，dev.255的attempt/partial生命周期闭包成立；剩余预下载浪费来自consumer-paced flow suspension仍按“精确target”记忆。
- 44次正frame-target `downloadStarted`中，按此前`flow-satisfied.completedFrames + committedLength`回放有22次无需重开：同一partial已经证明的完整帧数足以覆盖后来更低/相等的1/2/3/5帧target，却因target值变化或demand detach/re-add丢失suspension状态而重新open。
- `DownloadTransferOwner`现把该状态收成generation-aware `_FlowFrameProof`：只记录实际`completedFrames`与证明prefix，不再记录触发suspension的policy target；任意正target `<= completedFrames`且partial未回退即已满足。target=0 foreground unlimited仍必须继续，target高于proof才允许resume。proof跨role变化与短暂无demand保留，只在physical generation变化、partial回退、promotion/dispose时失效。

## 0.31.0-dev.255：scheduler cancellation 与 partial failure 解耦

- 03:19真机Trace中8次`downloadPreempted`全部victim base rank=0；其中5次随后把拥有真实committed partial的`DownloadSession`写成`Failure(cancelled)`，涉及约35.67MiB authoritative partial。相同physical partial还出现preempt后约364ms/618ms重新获得priority1000/820 demand，证明scheduler attempt cancellation被错误晋升成内容failure。
- `ErrorCode.cancelled`现统一只结束transport attempt：`DownloadJob`先flush已收到bytes并关闭iterator，再由`DownloadSession.pause(writer)`回到`idle/failure=null`；`DownloadSession.fail()`自身也拒绝把typed cancellation写成failed，避免chapter/restore等其他调用方复发。真实network/content/validator错误仍走failed。
- `downloadPreempted`继续作为NetLane调度事实，但新增`partialPreserved/partialState`诊断；本轮不改scrubbing current-only、3/7、5/3/2/1、NetLane 5+1/100ms candidate与restart-cost。连接仍可被稳定current preempt，但partial authority不得被scheduler cancellation污染。

## 0.31.0-dev.254：decode ingress epoch ownership 与 bounded flow suspension

- 02:27真机Trace中`taskFailed/sourceDisabled=0`但仍出现2次silent `DecodeState.failed`；page335成为current后physical download已从约8.36MiB原地`pseudo-resumed`并快速增长到15.1MiB、最终seal/promote，DecodeSession却在source继续演化期间直接failed且upload随之failed。根因是DecodeSession同时读取physical `DownloadSession.epoch`与Reader-local ingress/source epoch，generation authority重复；preflight返回failed snapshot又会被LiveCoordinator当成已消费source revision。
- DecodeSession不再持有physical DownloadSession：decode epoch只取当前`DownloadIngressProjection.snapshot.epoch`，异步decode期间generation变化作为生命周期cancel而不是内容failure；projection/source读取竞态先重读一次，仍不一致则等待新source revision。LiveCoordinator禁止静默消费returned failed snapshot，统一进入现有decode failure/recovery诊断。
- 同一Trace的`consumerPacing`有1800次`pseudo-drain`；target=1时completedFrames中位38、最大122，证明“每100ms放行一个chunk”最终会把远端动画慢慢下载完。unsupported pause现在只保留100ms同-response升水位机会；仍blocked则`pseudo-suspended`，正常pause writer并保留authoritative partial，TransferOwner把当前frame target记为已满足且不自动重开。只有flow target提高/current=0时才从partial启动新attempt。真实`streamBackpressure`不变。
- 3/7、5/3/2/1 frame credit、NetLane 5+1、provider/partial/progress ownership均不改。

## 0.31.0-dev.253：logical source watch physical-generation rebinding

- 01:44真机Trace中`taskFailed/sourceDisabled`均为0，但page81两次current分别约3.26s/至少5s始终`firstFrameReady=false`。其new physical session已从artifact cache完整获得18,699,622 bytes并`sourceReady/promoted`，对应DecodeSession却从77.92s起一直`waitingSource`；同一logical download此前曾verified-alias到旧physical owner，旧owner完成并退休后alias被机械清理，随后该logical exact创建新physical owner。
- 根因是`LiveCoordinator`按logical DownloadId缓存source listener，却没有记录listener实际绑定的physical session/projection；demand gap后同logical id重入时，旧listener使`_watchSource`提前返回，new physical sourceReady无人唤醒decode。现source watch显式持有logical→physical session/projection/listener binding；physical generation变化时解绑旧projection、清理source revision consumption、机械失效旧DecodeSession，并在本轮reconcile完成后从新projection重新wake。
- `DownloadIngressProjectionRegistry`同时识别“same DownloadId但新DownloadSession对象”的physical generation，旧Reader-local ingress/source不得跨generation复用；SourcePool entry机械替换。3/7、frame credit、consumer pacing、NetLane、partial/progress/provider均不改。

## 0.31.0-dev.252：sealed ingress幂等确认与resume-safe flow pacing

- 23:17真机Trace出现1次`sourceDisabled`：late Reader replay已seal native WebP后再次`expectLength`触发`reserve expected length`，native返回sealed并把Reader-local source禁用。`Ingress.expectLength`现把sealed+同长度视为幂等确认；长度不一致直接报artifact corruption，但不得再调用native reserve/disable可用source。
- 同一Trace的预下载resume暴露frame-credit自锁：已有partial已含多帧时，新network attempt从0/overlap追赶旧partial，却直接用authoritative completedFrames判断credit，出现`networkCursor < committedLength`仍pause。`DownloadJob`现冻结attempt起点的authoritative catch-up floor，probe/full-body replay在追到该边界前不受frame credit阻断，越过旧partial后才按远端帧水位限流。
- 两次`Bad state: StreamSink is bound to a stream`都发生在rhttp direct长时间hard pause→resume后。rhttp capability降为`consumerPacing`；伪pause不再无限停止消费，而是每100ms只放行一个chunk并记录`pseudo-drain`，credit提升立即原地全速resume。Dart HttpClient direct继续使用真实`streamBackpressure`。3/7、5/3/2/1水位、NetLane 5+1、partial/progress/provider lifetime均不改。

## 0.31.0-dev.251：unsupported transport consumer-pacing伪pause收口

- 16:42真机Trace中3/7 frame credit已产生35次真实`paused`/22次`resumed`，说明direct HttpClient/rhttp backpressure主路径成立；limited但未pause的远端候选主要是persistent artifact-cache本地读取，不应为了视觉一致性阻塞。新增typed `ByteResponseFlowControl.consumerPacing`，只给已知可安全分块消费但不能承诺上游网络pause的source body使用。
- `DownloadJob`对source body统一消费`none / consumerPacing / streamBackpressure` capability：streamBackpressure继续记录`paused/resumed`；consumerPacing达到同一frame credit后记录`pseudo-paused/pseudo-resumed`并停止继续迭代同一response，credit提升后原地继续。伪pause不声称节省已materialize的上游流量，不cancel/reopen、不创建第二task/session。
- runtime fallback与generic `LoaderTransport`显式声明`consumerPacing`；artifact-cache/resident仍保持`none`/既有resident路径并快速完成。没有提高NetLane连接上限，也没有引入paused-connection pool；16:42 Trace中9/9 preemption victim均曾flow-paused的问题单独保留，避免本轮把resume permit arbitration半实现进来。

## 0.31.0-dev.250：ByteResponse flow-control capability API 闭包修复

- 修复dev.249真实Flutter/Dart编译回归：`ByteResponse`构造函数已接收`flowControl`，但类体漏声明instance field，导致downloads wrapper与DownloadJob的`response.flowControl`全部无法解析；`downloads_bridge`同时因downloads facade未导出`ByteResponseFlowControl`而无法解析enum。
- capability ownership不变：`ByteResponseFlowControl`与字段唯一属于transport；downloads只在既有ByteResponse facade export中补导出该enum给downloads_bridge，不新增extension、diagnostics字符串分支或downloads_bridge→transport第二依赖。dev.249的3/7 frame-credit/backpressure policy与所有水位、NetLane、partial/progress行为完全不改。
- 新增dev.250 API-closure gate，同时检查enum、constructor parameter、instance field、facade export、direct transport赋值、wrapper透传与DownloadJob消费，避免无Dart环境下再次出现“符号字符串存在但公共API未闭合”的假通过。

## 0.31.0-dev.249：Animated WebP frame-flow backpressure inside stable 3/7

- 14:13真机Trace确认dev.247/248虽把preempt降到13次，但动画正常scrolling/idle期间46次policyDecision只保7个download demand；这优化了极端partial复用，却退化了更常见的“只看几帧就切页”3/7前瞻浏览。撤销previous2/next4 network eligibility与50MiB whole-body weighted admission：RoleWindow与实际DownloadDemand都恢复完整previous3/next7。
- 动画成本改为per-task frame flow credit而非page/count/estimated-body admission。current/可见transition unlimited；next/next2/previous分别5/3/2帧；其余3/7远端先1帧，并由既有`c>4/n>2/c>6/n>3`水位把对应外层提高到2帧。static/non-WebP不受该cap限制。
- `DownloadJob`新增轻量RIFF/ANMF边界计数，只在transport显式声明`streamBackpressure`时生效；达到credit后停止请求下一个response chunk，保留同一NetLane task、HTTP response、physical writer与partial，水位/role提升后原地resume。HttpClient/rhttp direct声明该capability；artifact-cache/resident/整包runtime fallback不做假流控。网络连接上限本轮仍为normal5+current-reserved1，不同时提高retained socket数量。

## 0.31.0-dev.248：Animated speculative byte-weighted NetLane admission

- 14:13 真机 Trace 证明 dev.247 的 previous2/next4 demand 窗口已生效且 preempt 降至13次，但动画 floor 的未知页估算固定约72MiB，默认50MiB预算只报警、不约束执行；水位扩张也因此几乎失效。
- 保持 previous3/next7 逻辑/retention 上界与 previous2/next4 最低预下载资格窗口；预算不再从 Pipeline 删除 eligible demand，而由 NetLane 对 active speculative encoded work 做通用 byte-weighted admission。
- current/visible transition 以 rank>=900 绕过 speculative budget，但保留估算成本；任务一旦降为 background，同一 physical task 立即计入预算，不 cancel/recreate。默认未知动画页12MiB，因此50MiB通常同时运行最多4个 speculative transfer；单个超预算页面允许独占预算以避免永久饥饿。
- 水位 c>4/n>2/c>6/n>3 继续把 outer page 加入候选队列；它们只在 active speculative byte budget 允许时进入执行。NetLane count concurrency、current reserved slot、dev.246 stable destructive-preemption transaction 均保持。

## 0.31.0-dev.247：Animated WebP layered prefetch window

- 保持 Reader previous3/next7 逻辑/retention窗口，动画/保守WebP只把network admission下界收为previous2/next4；既有decode水位按 c>4 / n>2 / c>6 / n>3 逐层开放next5 / previous3 / next6 / next7。
- 新增默认50MiB、可在网络设置调整的动画WebP speculative encoded预算；2/4硬下界优先，外层扩张受预算约束。
- decode refill只向Pipeline回报revision-scoped完成milestone，跳页后的stale refill不得重新扩张新current窗口；runtime static事实立即恢复完整3/7。

## 0.31.0-dev.246：Stable destructive preemption candidate 与 single-flight cancellation

- 12:15真机Trace中dev.245已将normal-pressure preemption清零，但仍有67次`downloadPreempted`且全部来自current=1000；它们只形成28个<=50ms burst，39次属于同一burst中的额外victim，最大66ms内连续cancel 6条。30个victim已有committed partial，合计约246.7MiB，最大约16.6MiB。
- 快速scrub的`pageCurrent`间隔明显双峰：中位约10.6ms、85%约88ms、90%已跃升到约594ms；17/28个preemption burst在100ms内current又变化，覆盖46/67次cancel。故撤销dev.245 victim-side 200ms demotion grace，改为NetLane-owned 100ms blocked high-priority candidate grace：free/reserved slot仍立即admit current，只有真正需要破坏性cancel时才要求incoming current稳定。
- destructive preemption改为single-flight transaction：已有preemption victim尚未物理退出时禁止再cancel第二个active task；退出后统一重新pump。victim仍只由`NetPolicyRank`/restart-cost选择，不把普通可恢复`committedLength`误当不可恢复sunk cost。`downloadPreempted`新增`incomingWaitMicros`便于真机验证。

## 0.31.0-dev.245：Current borrow-first 与 bounded demotion rank hysteresis

- 10:54真机Trace中87次`downloadPreempted`导致24/24 download failure均为cancelled；59次由current1000触发、28次由780/800/820/900 normal pressure触发。current victim全部已经detach为base0，detach→preempt中位约93ms、75%约196ms。
- 最终图片NetLane删除normal-pressure preemption：normal work只排序等待普通slot；normal5满时current先直接借唯一reserved第6槽，只有5+1真实饱和才允许统一rank preempt。
- Reader active priority下调增加200ms NetLane-owned demotion-preemption grace；窗口内effective victim rank保持在current margin之外，重新获得demand立即清除保护，窗口到期自动repump。restart-cost曲线与Venera单context gate不变，不恢复dev.202 headroom实验。

## 0.31.0-dev.244：Admitted provider stability + transport cursor dual progress

- 09:47真机Trace中verified-equivalent acquire继续复用既有physical owner，但仍记录55,743,710 bytes重复prefix：44,741,284来自Range→200后的full-body catch-up，10,412,602来自catch-up尚未越过已有partial前又被取消/抢占。两次`active-provider-handoff`还会仅因logical exact/current变化在同一shared physical partial内取消已admit provider并改用另一等价URI，属于可避免的transport churn。
- 删除rank驱动的active provider replacement：logical claim只迁移同一physical NetLane task的priority；provider exact/request URI固定为admitted task lifetime事实，直到完成、失败或真实consumer-bound transport lifetime失效。NetLane统一policy rank仍只负责physical slot/preemption，不再顺带决定等价provider URI。
- `DownloadSession`新增只读transient network cursor/attempt sequence，由`DownloadJob`按实际response消费推进，和authoritative committed partial严格分离。Pipeline progress只从同一个resolved physical session投影两者，并按VibeVenera实际Reader实现采用128KiB/s→8MiB/s对数红/琥珀/绿速度色及0.7/0.3平滑。
- Reader下载提示改为双层：已有/最大authoritative partial保持theme secondary直线；当前transport cursor使用速度着色波浪线。transport落后于partial时明确表示prefix replay，不把重读字节伪装成partial增长，也不让UI参与下载控制。
- 新增dev.244 ownership gate、provider-stability行为回归、transport-cursor/progress行为回归、ADR 0224与Trace根因审计；历史dev.237/238/240/241 gate改为版本感知，不保留已删除的provider takeover兼容控制流。

## 0.31.0-dev.243：Atomic late ingress publication + active rank-zero retention

- 09:03真机Trace在dev.242 physical partial/progress统一后暴露新的流式回归：12次task failure中11次是`Bad state: native source is disposed`，全部发生在unsealed decode；根因是late Reader synchronized replay在physical committed boundary继续增长时反复`rebuild -> Ingress.reset -> source.dispose`。现late replay在追平期间保持source unpublished，同epoch移动边界只从artifact追加新suffix，稳定接入live fan-out后才一次性publish source。
- cross-session短暂demand gap仍有一条绕过统一rank的旧控制流：最后claim消失时receiving active会降priority 0，但pre-open/source-plan active却直接`net.cancel()`。现所有already-admitted active task统一降为`retained-background=0`，由NetLane统一policy rank决定何时抢占；只有从未admit的queued task可`cancelQueued`。这也避免直接cancel产生cancelling-active窗口后阻塞普通pressure arbitration。
- 新增late replay不可见/稳定source identity、pre-open active rank-zero retention与NetLane policy preemption回归；dev.177/dev.184历史gate改为版本感知，不为旧源码形状恢复receiving/pre-open分支。

## 0.31.0-dev.242：Acquire-before-projection physical closure + provisional WebP prefix decode

- 07:51真机Trace确认“同图不同progress”不是progress widget问题：current页面在demand reconcile前由`PipelinePageStream`调用`DownloadRegistry.get(exact)`提前创建exact physical session，使composition verified-equivalence resolver命中`findExact(exact)`后无法acquire-time alias；neighbor/prefetch因没有该presentation副作用反而能复用旧partial。现Pipeline所有presentation/read-only路径只允许`find`，physical session只能由transfer acquire/reconcile创建；PageStream先以logical identity存在，reconcile完成后再refresh到resolved physical owner。
- `PipelinePageStream`不暴露session注入API，只持有Pipeline-owned non-creating resolver；Reader retain/dispose会显式解除其snapshot listener。`loadBytes`、direct immutable read与startup readiness同步删除隐式`_downloads.get()`，避免其他presentation fallback再次制造exact owner。
- 同一Trace唯一decode `taskFailed`发生在current WebP首帧、source=786432且unsealed，后续同一图片source增长到8,380,120后可连续解码。DecodeSession现仅对“unsealed + 尚无成功帧”的decode exception沿既有prefix-hint/source-wake路径降级为provisional wait；sealed source或已有成功帧后的异常仍保持authoritative failure。跨session rank不再新增策略分支：verified-equivalent current先统一到一个physical task后继续使用dev.241统一rank。

## 0.31.0-dev.241：Unified transfer policy rank

- 收口dev.237–240逐步堆出的provider handoff情况分支：`orphaned/high-priority/strict-higher/restart-cost`不再各自决定控制流。Pipeline仍只产出semantic demand priority；NetLane现公开`NetPolicyRank`，用同一restart-cost retention曲线计算incumbent effective rank并拥有rank margin比较；provider owner只提交candidate priority与incumbent base priority。
- active provider claim存活时使用其当前priority作为incumbent base；claim orphan后沿用lease admission priority。same-exact仅作为“request authority无需更换”的identity no-op，transport retainability/consumer dispose继续是lifecycle capability/invariant。provider takeover Trace统一为`takeoverClass=policy-rank`并记录effective rank、retention bonus、restart cost与margin。
- costly full-body catch-up的1MiB/8MiB与820/900条件也从`DownloadTransferOwner`移出到`TransferRankPolicy`：required completion只提升demand rank，最终统一做`demand rank >= cost rank`。新增NetLane rank、provider margin和catch-up rank行为回归；删除sessions中的high-priority/orphan/strict-higher重复policy判断。

## 0.31.0-dev.240：Current reclaims orphaned cross-version provider authority

- 05:35真机Trace共4553条事件，跨新旧版本切换时physical task的aggregate priority会正确迁到current=1000，但active provider exact URI可继续停在更早Reader的task-retained orphaned lease；代表性physical transfer在reader-2/reader-3已成为current时仍由reader-1 provider服务，整份Trace `active-provider-handoff=0`。因此表面是“current无法抢占”，实际不是NetLane reprioritize失效，而是request/provider authority未随high-priority demand迁移。
- provider handoff现区分普通orphan retention与high-priority reclaim：低于NetLane high-priority threshold的adjacent/background demand继续保留已admit orphaned attempt；不同exact provider的high-priority demand必须取消旧provider attempt并在同一physical `DownloadSession`/writer/committed prefix上由preferred exact provider重开。判定只调用NetLane的`isHighPriority()`，sessions不认识Reader role或硬编码1000。
- task-retained且provider exact与preferred exact相同的attempt不因Reader generation变化重开；live provider仍维持strict-higher priority handoff。新增current跨版本orphan reclaim行为回归、dev.240 ownership gate与ADR 0220。

## 0.31.0-dev.239：Task-retained loader transport lease

- 05:09真机Trace共1176条事件，dev.238已消除claim orphaning导致的provider churn：`taskFailed=0`、无orphan handoff、无`full-body-prefix-catchup-aborted`，resume duplicate仅一次65,536-byte overlap proof。剩余断点是Reader consumer真实dispose仍取消loader-backed active task，4–8MiB hot partial随后必须重新resume；其中4,064,640-byte partial因服务器Range→200进入full-body catch-up。
- transport lifetime现显式分为consumer-bound与task-retained。`DownloadTransferConsumer`可提供通用`retainedTransportFor(uri)`；active task启动时取得独立lease后可越过provider consumer dispose继续同一physical session/writer/committed prefix。consumer dispose仍cancel+idle所有consumer-bound lease。
- Pipeline只对`LoaderTransport`实际拥有的URI提供retained capability；其controlled loader来自composition/source gateway且无Reader closeable client。Reader-owned`IoTransport`明确排除。sessions/downloads不感知Venera/Mihon/source类型，也不建立第二transport registry。新增`providerTransportLifetime`诊断与行为回归，同时保留consumer-bound transport dispose→cancel→remaining provider reopen的旧安全合同。

## 0.31.0-dev.238：Retain admitted provider attempt across claim orphaning

- 04:46 真机 Trace 共943条事件，dev.237 provider handoff真实命中8次且全部是`providerOrphaned=true`；没有一次来自live provider被更高priority claim压过。Trace中的resume duplicate约2,237,360 bytes，其中1,909,680 bytes直接来自一次`full-body-prefix-catchup-aborted`。
- 根因收窄：physical partial、progress与provider exact identity已经分层，但dev.237仍把“provider claim撤销”错误等同于“已admit provider transport失效”。Reader generation切换会立即取消仍有效的active response，白白丢弃已经支付的source-open/full-body catch-up工作。
- `DownloadTransferOwner`现在允许active provider lease在claim detach后成为retained-orphaned lease：只迁移同一个NetLane task priority，不因logical claim消失切换provider。只有provider claim仍live且新的preferred claim priority严格更高，或provider consumer真正dispose、其transport owner即将关闭时，才取消旧attempt。
- consumer dispose路径删除重复`net.cancel()`：provider key先收集用于idle barrier，唯一取消发生在`_detachClaims(... consumerDisposing: true)`。physical session/writer/committed prefix、provider-scoped validator、durable partial与progress authority均不变。
- 行为回归改为证明：old claim detach + new exact alias demand不会打开第二provider；physical session/committed prefix保持；只有old provider consumer实际dispose后才reopen remaining exact provider。

## 0.31.0-dev.237：Active provider lease handoff on shared physical partial
- 04:17真机Trace确认dev.236进度projection已指向physical session，但“切换session后partial进度不增长”并非publisher漏通知：physical `committedLength`在full-body catch-up重读旧前缀期间本就保持不变。关键冗余是active network task仍被最初启动它的Reader provider钉住；新current claim只把同一NetLane task priority抬到1000，却不切换provider exact URI/transport。
- `DownloadTransferOwner`现把active source provider建模为task-scoped lease（task key + consumer scope + exact provider + claim sequence）。active provider claim已撤销，或另一个live claim以严格更高priority成为preferred时，旧attempt由同一NetLane取消；旧writer退出后在同一physical `DownloadSession`/artifact/prefix上由preferred exact provider重新开task。equal-priority不抖动，queued task仍在真正run时选择preferred claim。
- 不把duplicate catch-up bytes计入可见progress，不复制partial，不late-merge session，也不改变NetLane/full-body admission。补行为回归覆盖“retained orphan provider → 新exact current provider”在已有prefix上rebind，以及dev.236 publisher对同一physical session后续committed增长持续推送。

## 0.31.0-dev.236：Physical partial progress projection closure
- 03:34真机Trace确认physical partial字节复用真实存在：15次verified acquire alias继续join既有owner；current page 303直接继承1,946,180 bytes，page 300直接继承3,314,200 bytes。但Reader进度仍“各走各的”，根因是`PipelineTransferProgressPublisher`另建按exact `DownloadId.key`索引的session表，而acquire-time alias的logical exact key与physical session key不同。
- 删除exact-key progress表与`observe(session)` fan-out；`PipelineReaderSession`先完成`binding.accept`建立physical alias，再由`DownloadRegistry.find(currentDownload)`解析唯一physical `DownloadSession`并直接交给publisher。进度只监听当前physical session snapshot，不复制committed state，不在Reader建立第二份进度cache。
- Reader-local ingress诊断scope改用physical `sessionId`，不再把旧physical anchor的exact identity伪装成当前projection identity。网络/partial/cold-store/provider URI/NetLane语义不变；本Trace剩余19,782,164 duplicatePrefixBytes属于真实200 full-body catch-up/overlap成本，另有1次unsealed partial-source decode failure，继续独立追踪。

## 0.31.0-dev.235：Provider-scoped resume validators
- 02:58真机Trace确认partial复用不是缺失：15次verified acquire alias全部join既有physical owner，4次multi-owner全部`preferred-existing-owner`；dev.234 retention后Reader dispose的physical session规模稳定为41→41→41→42。与此同时4次full-body prefix catch-up累计13,466,264 duplicate bytes。
- 对照dev.227 provider-exact request identity后定位冗余下载根因：physical session共享committed prefix是正确的，但ETag/Last-Modified没有记录产生它的provider URI；跨版本B借用physical A时会把A validator发给B，Trace中704,512-byte A partial切到B后`strongRangeRejected→200 full-body`，随后切回A URI又能206。
- `DownloadSession`现将validator与actual provider request URI绑定；`DownloadJob`、resident replay、Pipeline immutable replay与cold partial handoff统一经`resumeValidatorsFor(uri)`取strong validator。scope mismatch保留partial/totalLength并走既有validatorless overlap，不再错误发送foreign `If-Range`。v2无scope metadata只丢validator知识、不丢partial或totalLength。删除仅测试仍引用的`residentCacheBacked/begin|append|sealDurableCachedIngress`兼容别名。

## 0.31.0-dev.234：Bounded physical transfer retention
- 01:41真机Trace确认dev.233 multi-owner收口生效：38次verified acquire alias中4次`candidateOwners=2`全部选择`preferred-existing-owner`，`rejected-ambiguous-existing-owners`与`taskFailed`均为0；promotion自动handoff重复probe仅剩2次`skip-existing`。同时4次Reader dispose时共享physical registry规模从43→50→100→107持续增长，说明logical claim detach不再错误cold-store之后，composition hot owner缺少自己的有界退休策略。
- 新增downloads层`PhysicalTransferRetention`：idle promoted session先等待既有ordinary artifact handoff收敛后机械退休；unfinished idle partial仅在composition hot预算超过32 sessions或256 MiB时由既有`PartialDownloadHandoff`cold-store，再退休physical session。cold-store失败必须保留hot owner，不得为预算丢prefix。
- sessions层只新增无持久化语义的idle physical retirement primitive，retire同时清理acquire-time physical aliases；Reader/Pipeline不持有retention budget。`PartialDownloadHandoff.persist`负责同session写入合并并返回成功语义，runtime dispose仍作为最终cold handoff边界。

## 0.31.0-dev.233：Physical reuse and handoff lifecycle consolidation
- 01:05真机Trace确认dev.232的`partial-source taskFailed`归零，但28次verified acquire alias中仍有2次`rejected-ambiguous-existing-owners`；ambiguous fallback会让fresh exact identity再创建第三个physical owner。现对direct verified existing candidates做authority排序，优先复用promoted/active/demanded/longer-prefix既有owner，绝不事后merge两个已存在session。
- 删除`sessions/DownloadTransferOwner.persistUnclaimed`及其flush状态：logical demand detach只释放调度claim，hot partial继续属于composition runtime；只有runtime真实retire/dispose才由downloads层`PartialDownloadHandoff`写cold partial，durable策略不再反向注入sessions。
- `PromotedArtifactCacheHandoff`对同一promoted immutable session的自动commit成功后记账，后续demand/snapshot抖动不再重复做`skip-existing/skip-verified-equivalent-durable` backend probe；显式`persist(exactId)`仍始终执行required durable barrier。

## 0.31.0-dev.232：Same-epoch encoded source rebind
- 00:38真机Trace出现3次decode `partial-source taskFailed`，但对应页面随后随source增长恢复；根因不是libwebp终局损坏，而是Reader-local `Ingress.rebuild()`可在同一SourceEpoch内替换EncodedSource，DecodeSession却只按epoch复用旧cursor。
- DecodeSession现在把cursor binding收口为`SourceEpoch + EncodedSource实例identity`；same-epoch source replacement会释放旧cursor/holder并绑定当前authoritative source，不增加外层retry、不吞未sealed异常。
- 新增same-epoch projection rebuild行为回归与dev.232 ownership gate；本Trace未命中`stored-required-exact-alias`，因此dev.231 required exact设备验证仍保持待验证。

## 0.31.0-dev.231：Required exact durable target without physical-anchor copy
- 00:19真机Trace确认dev.230 equivalence-only artifact ownership稳定：43次acquire alias、无task/session/writer failure，cold partial等价恢复继续命中；普通Reader已有等价durable body时出现`skip-verified-equivalent-durable`。
- required offline completion不再先materialize physical anchor再复制到consumer exact ID；promotion handoff读取physical owner的required exact targets，直接把hot/resident bytes落到required exact identity。普通Reader无required target时保持原physical exact/verified-equivalent skip语义。
- `persistPromoted(exactId)`只验证acquire-time alias并等待/确保该exact durable target；共享physical A服务required B时新增`stored-required-exact-alias`诊断，B完成后A不会仅因B命令被额外持久化。

## 0.31.0-dev.230：Equivalence-only artifact ownership
- 23:45真机Trace确认dev.229迁移生效：`version-durable-partial-reused`归零，`session-partial-handoff/restored-equivalent`真实命中，25次acquire alias继续工作且无`taskFailed/sessionBusy/writerBusy`；版本等价proof已足以承担full/cold复用，不再需要directed hard artifact alias/rekey。
- 删除`ArtifactCacheManager` hard alias map、resolve/alias/rekey API及`VerifiedArtifactReusePlan.apply/applyExisting/rekeyExisting`；显式漫画源迁移改为登记symmetric verified equivalence，exact DownloadId始终保持durable write authority。
- 普通Reader promotion若已有direct verified-equivalent durable artifact则直接复用，不复制第二份exact durable body；只有显式required-completion barrier才materialize exact durable identity。

## 0.31.0-dev.229：Equivalence-aware cold partial restore
- 23:03真机Trace确认dev.228删除late takeover后9次acquire alias（4 receiving / 1 failed）继续工作，`taskFailed/sessionBusy/writerBusy`为0；同时版本warmup仍有4次`version-durable-partial-reused`，证明旧的跨版本cold partial复制补偿仍在实际命中。
- 删除version warmup/Reader入口的`applyDurablePartials`复制路径；`PartialDownloadHandoff`改为physical prepare时exact-first、direct verified-equivalent fallback，并从候选中选择最长cold partial直接恢复，不提前创建目标exact durable partial副本。
- 跨版本cold partial恢复清空ETag/Last-Modified，继续由DownloadJob validatorless overlap proof决定是否接受resume；live physical acquire alias、NetLane、retry、水位、artifact durability不变。

## 0.31.0-dev.228：Remove late equivalent-promotion takeover
- 15:57真机Trace确认dev.227后18次verified acquire alias（含8个failed partial）不再产生`unsupported URI scheme`或task/decode failure，legacy `verified-equivalent-promotion-takeover`继续0命中。
- 删除composition artifact-promotion listener、`DownloadTransferOwner.refreshIndependentExactForPromotedEquivalent`以及ArtifactCacheManager promotion observer API；verified relation对physical identity的唯一实时副作用收口到demand acquire。
- 保留direct verified equivalence registry与physical→durable partial/artifact persistence；两个已经独立创建的physical session仍不事后merge。

## 0.31.0-dev.227：Provider exact request identity closure after physical alias
- 15:29真机Trace确认dev.225 Phase C1真实命中13次acquire-time alias，其中6次加入可恢复failed partial；但随后43次network task全部因`unsupported URI scheme: venera-resource`失败。根因是owner按provider exact URI选择transport后，`DownloadJob`仍用physical `session.id.canonicalUri`执行open，跨版本alias时把旧anchor URI泄漏进新Reader transport。
- `DownloadJob`新增显式`requestUri`：artifact/writer/resume/validator状态继续属于physical session，所有source open/range probe/resume请求只使用当前provider exact URI；legacy caller默认仍用session URI。新增failed partial + verified-equivalent provider URI行为回归和dev.227闭包gate；本轮暂停继续删除late compatibility path。

## 0.31.0-dev.226：Phase E late-takeover contraction and alias observability
- 依据15:01真机Trace收缩verified-equivalence补偿：删除无生产调用者的Reader/consumer late-takeover委托，仅在composition owner保留独立exact session的legacy compatibility takeover。
- promotion listener改为`findExact`独立session检查，acquire-time physical alias不再被late compatibility扫描；新增`verified-transfer-acquire-alias` join/ambiguous诊断和compatibility scope标记。
- 保留physical transfer→durable partial/artifact persistence：本轮Trace仍实际命中12次partial stored与48次artifact persistence，不能因历史`session-handoff`命名机械删除。

## 0.31.0-dev.225：Verified equivalent physical transfer alias before acquire
- 在composition physical owner中新增acquire-time verified alias：新exact identity尚无session且direct verified equivalence唯一命中已有有authority的physical session时，claim在创建session前加入该transfer；不做事后session merge。
- `DownloadTransferOwner`按physical identity聚合claim，同时保留每个claim的exact `DownloadId`作为provider URI/source bucket；source-resident非artifact-cache body禁止跨版本join，避免把可重开source误当成共享encoded body。
- 章节command改为先提交claim再获取session；通过等价physical transfer完成后仍materialize章节自己的exact durable artifact。late takeover/session-partial兼容路径暂保留。

## 0.31.0-dev.224：Chapter migration compile closure
- 修复`PersistentDownloadArtifactStore`漏迁的durable artifact write single-flight字段，保持store而非command拥有写入去重与close barrier。
- 修复`LiveCoordinator`迁移残留的越作用域`update.plan`引用，改为从coordinator当前`_downloads`全集投影`TransferDemand`；删除`advanceDueFrame`重复局部声明。
- 新增dev.224迁移编译闭包gate；不改变dev.223 composition transfer/chapter claim架构。

## 0.31.0-dev.223：Composition transfer runtime / chapter command claim migration

- dev.222真机scrub边界验证稳定后，将physical transfer runtime从Reader私有实现提升到downloads/App级composition owner；Reader、prefetch与显式章节下载对exact `DownloadId`共享单registry/writer/network/retry/hot-partial，whole-comic继续只聚合章节命令。
- 拆出`PersistentDownloadArtifactStore`与`PersistentDownloadComposition`，command contract不再等于cache owner；显式下载完成需等待promoted artifact真正handoff到唯一durable store。`TransferDemand`新增required completion intent，使低优先级离线命令不被Reader机会性full-body catch-up admission永久defer。
- 迁移时进一步拆开resident immutability与durable body ownership：新增`ByteResponseBodyAuthority`，生产代码改用`residentBodyBacked/residentBodyAuthority`；source-resident只在显式required-completion时经composition consumer/source replay materialize到唯一ArtifactCacheManager/store，避免local immutable被误判为cache-owned。

## 0.31.0-dev.222：Live slider scrub / foreground demand boundary

- slider拖动实时跳页，scrub期间Pipeline只保current foreground demand；松手恢复正常窗口。

## 0.31.0-dev.221：resident encoded-source replay authority 收口

- 修复composition physical transfer提升后的late Reader黑页：`residentCacheBacked` session不再从可能为空的session artifact重放；Reader-local projection由独立replay authority从`ArtifactCacheManager`或可重开immutable local source重建authoritative prefix。
- resident replay继续使用共享`ArtifactCacheReadScheduler`，避免Reader重入把durable/local encoded reads扩成旁路I/O并发；NetLane、水位、retry、cache ownership与verified TransferKey均不变。

## 0.31.0-dev.220：Reader scrub intent / physical trace fan-out closure

- 09:44 真机Trace确认dev.219 late Reader decode/upload已恢复，但一次slider 148→248拖动仍在约0.4s内提交23次pageCurrent、23次policy replan和157次download priority重排；现slider拖动改为UI-local scrub preview，只有gesture end提交一次Reader navigation request，避免PageView/Pipeline/physical demand被中间索引逐格驱动。
- ReaderBinding先推进Reader-local viewport fact，并在pipeline reconcile成败后都同步playback projection；physical `_TransferTraceHub`改为Reader memory sink逐Reader保留 + shared App/export sink identity引用计数，消除overlap Reader把同一physical event重复写入全局Trace。App提升到`0.31.0+220`；NetLane/水位/retry/cache/transport/verified TransferKey均不改。

## 0.31.0-dev.219：Reader / Pipeline observation-projection boundary

- 08:19真机Trace确认共享physical owner后的关键跨层回归：Reader3 plan有11 download/4 decode/4 upload，但late Reader对已有committed session同步attach native ingress时异常截断reconcile，最终本Reader decode/upload session均为0，current页21秒无首帧。
- Reader-local ingress registry现在对已有prefix先返回consumer projection，再异步`synchronized` replay；replay失败仅标记本地projection，detach可自清理late fan-out，不枚举/拥有composition physical registry。
- Reader observation改为enqueue/latest-wins microtask seam，pipeline reconcile不再同步处于scroll/page-request栈；DecodeTarget变化不再detach/attach binding，而只更新PipelineController target并在下一条observation中从既有plan增量diff，physical download demand保持连续，ReaderController/requested page不重建。App提升到`0.31.0+219`；verified TransferKey继续冻结。

## 0.31.0-dev.218：Source-wake / slider closure

- 07:34真机Trace确认dev.217网络单task修复有效：本轮无`sessionBusy/writerBusy`且存在15次`downloadPreempted`。黑页根因转为decode wake：页面334的physical source/artifact已就绪，但其DecodeSession在此前`waitingSource`后46.28秒未首帧。
- 修复`LiveCoordinator`把staged refill的null误当作source已消费：current bootstrap暂时门控next/next2时保留pending source revision，只有实际fill或DecodeSession明确无需fill才consume；同时直接读取Reader-local ingress projection当前revision作为edge-loss兜底，角色晋升current后可从已就绪source恢复。
- Reader slider受控值从`currentIndex`改为`requestedIndex ?? currentIndex`，避免拖动期间request尚未acknowledge时被旧current rebuild拉回。新增source-ready prefetch被门控后晋升current的Dart行为回归、真实slider gesture回归、dev.218静态gate/审计。App提升到`0.31.0+218`；verified TransferKey继续暂停。

## 0.31.0-dev.217：Prefetch single-transfer task closure

- 真机`zic-debug-trace-2026-08-11T05-59-23.jsonl`确认dev.216并非单纯prefetch policy退化：出现51次`Failure(sessionBusy)`、2次`writerBusy`，并由`sessionBusy`产生114次`download-attempt` retry。根因是`DownloadTransferOwner._ensureDownloadTask()`发现既有task key后只迁移priority却未返回，policy revision会为同一exact `DownloadId`持续制造不同NetLane key并并发撞击同一DownloadSession。
- 修复为queued/active exact id的task identity稳定：existing key仍在NetLane时只原位更新priority并返回；只有lane已退休stale key才允许重新submit。`_runDownload`增加stale-key start guard，调度前同时拒绝`activeRun/hasWriter`，避免第二physical run。
- 新增“lane被占用时连续700→720→780→1000 revision仍只有一个queued task key、最终只open一次transport”的Dart回归；新增dev.217静态gate/审计。verified TransferKey与chapter/whole-comic迁移暂停，先完成预下载/切页真机复验。App提升到`0.31.0+217`。

## 0.31.0-dev.216：Composition Physical Transfer Owner

- `DownloadTransferOwner`提升为exact `DownloadId`的composition physical owner：共享`DownloadRegistry`、active writer/network task、retry/terminal/defer与scoped claims；`LiveCoordinator`只保留Reader demand/decode/upload协调。
- `PipelineReaderSessionFactory`所有clone共享transfer-runtime pool，runtime key按artifact cache manager + partial store + shared NetLane的真实owner identity组成；loader/UA/Reader transport只作为consumer provider，不产生第二physical owner。
- 两个Reader请求同一exact id时复用一个session/writer。active provider退出会先取消并等待其task真实退出，再由remaining consumer以自己的transport继续；Reader-local ingress projection/decode/upload仍隔离。
- 最后claim消失且已有committed partial时，physical owner在writer退出后通过现有`PartialDownloadHandoff`立即持久化，避免composition runtime继续存活造成冷启动partial丢失。新增ADR 0197、dev.216审计/ownership gate与三组Dart行为测试；App提升到`0.31.0+216`。verified跨版本TransferKey与chapter/whole-comic/prefetch claims留待下一阶段。

## 0.31.0-dev.215：Reader-local Ingress Projection 所有权拆分

- physical `DownloadSession`移除唯一Reader native `Ingress`/source-listener所有权；新增Reader-local `DownloadIngressProjection`与registry，DecodeSession显式消费本Reader source，artifact/writer/resume仍归physical session。
- late consumer对已有committed prefix使用revision/epoch/length/sealed稳定回放后无await附着；回放期间physical mutation会使本轮失效重试，避免active writer与native ingress replay发生offset交错。
- physical `DownloadRegistry`、network task/retry/terminal仍保持Reader-local；本轮不宣称cross-Reader active transfer已启用。新增ADR 0196、dev.215 ownership audit/gate，App提升到`0.31.0+215`。

## 0.31.0-dev.214：Image Transfer Consumer Claim 所有权前置重构

- 重新审查 dev.213 与 VibeVenera 后确认：ZIC 不能只把 Reader-local `DownloadRegistry` 提升为 global map。当前 `DownloadSession` 同时绑定 Reader-local native `Ingress`，而 `LiveCoordinator` 还拥有 network task/retry/terminal 状态；机械共享会把 A Reader 的 cancel/retry 泄漏到 B，或把 decode ingress错误全局化。
- `DownloadSession` 新增 scope-based `DownloadDemandLease`：多个 consumer 独立 attach/update/detach，`effectivePriority` 取最大 claim 而非求和；legacy direct `DownloadJob` demand 仅保留为兼容入口。
- `LiveCoordinator` 的 Reader demand 改为 claim：离开只撤销本 Reader claim；若仍有其它 consumer，活动 transfer 不取消，并按剩余最高 priority 降级。`DownloadJob` 在 Reader path 不再偷偷重新建立 legacy demand。
- 本轮故意不宣称跨 Reader hot partial 已完成：物理 registry、network retry owner 与 Reader-local native ingress projection 仍需下一阶段拆分后才能安全提升到 composition。现有 durable partial、verified artifact equivalence 与 dev.213 late full takeover 保持兼容。
- 新增 ADR 0195、dev.214 ownership audit/gate 与多 consumer claim regression；App版本提升到 `0.31.0+214`。

## 0.31.0-dev.213：等价 Full Promotion Takeover 与 Session Partial 边界

- 对照 `zic-debug-trace-2026-08-11T03-35-42.jsonl` 与 `vibevenera-master.zip`，确认VibeVenera通过alias-before-DownloadIdentity使版本页共享同一 `_loadingImages` / `_PartialImageCache` / DownloadSession identity，等效具备session/in-flight partial复用；ZIC不直接提升为跨Reader共享writer。
- 新增immutable artifact promotion observer：相关版本full迟到落盘时，活跃等价DownloadSession保留自己的committed prefix，仅替换当前network attempt；下一次DownloadJob open从ArtifactCacheTransport读取equivalent full剩余range。
- local full出现可解除旧network terminal/retry/defer记忆；cache-resident session不重复takeover。
- 修复dev.212 stale mapping仅因页数未变就跳过strong revalidation、导致`verifiedAt`永远不刷新的错误。
- origin/read trace新增`verifiedEquivalentCandidates`，区分mapping覆盖缺失与“候选存在但尚无full”。durable inactive partial规则不变，不共享hot writer。
- 新增ADR 0194、dev.213审计/owner gate和promotion-listener regression，版本提升到`0.31.0+213`。

## 0.31.0-dev.212：版本 mapping 严格解码与后台重验证收口

- 修复 dev.210/211 新增 `ComicVersionPageMapping.verifiedAt` 的 Dart 静态类型遗漏：JSON 原值先收窄为 `String?`，再用 `DateTime.tryParse` 严格验证并转 UTC；非法类型/非法时间继续抛 `FormatException`，不使用宽泛 cast 绕过。
- 结合 `zic-debug-trace-2026-08-11T02-25-52.jsonl` 确认 dev.211 verified-equivalence 已真实工作：Reader 前恢复 3 个 mapping / 1113 个等价页，后续多次 `sourceRead` 明确 `verifiedEquivalentReuse=true`；不再改 full-artifact fallback。
- 同一 trace 同时显示已持久 mapping 在约94秒内重复产生15次 `version-page-mapping-warmed`，多数没有新增 equivalent page。版本发现仍每次详情/Reader异步执行，但最近10分钟内所有 page mapping 都有有效 `verifiedAt` 时跳过昂贵的 `loadComic + strong page identity` 重验证；新 relation、缺时间戳或过期 mapping仍重新验证。
- durable inactive partial 复用与 DownloadJob overlap probe保持不变；trace已显示该路径实际复用并成功 resume。
- 新增 ADR 0193、dev.212根因审计/owner gate与 mapping JSON regression test，版本提升到 `0.31.0+212`。

## 0.31.0-dev.211：版本 artifact 等价 fallback 与迟到缓存复用

- 结合 `zic-debug-trace-2026-08-11T02-00-30.jsonl` 确认 dev.210 的 mapping 已完成但 full reuse仍是一次性快照：再次进入371页旧版前已有3个 persistent mappings，却只 `reusedPages=13`；相关377页版本随后继续完成的 immutable artifact不会再进入旧版。
- 对照 VibeVenera 临时 image-key alias 语义，将 verified page mapping 从“仅对当前已存在文件注册 directed alias”升级为 `ArtifactCacheManager` 的 symmetric verified-equivalence fallback：登记时不要求任一侧已有 artifact，lookup exact-first，miss后才查已验证相关版本；任一侧未来才promote的artifact也能被另一侧后续demand复用。
- equivalence只影响 immutable artifact lookup，不重定向写入、不改变 `resolveAlias`、不形成双向alias环；目标版本已有自己的exact artifact时永远优先。Trace新增 `verifiedEquivalentReuse` 与 `version-artifact-equivalence-restored`。
- partial结论保持dev.210的保守边界：新trace已证明durable partial跨版本复用实际发生，hot Reader/DownloadSession partial仍禁止共享；本轮不扩大partial owner。
- 新增 ADR 0192、dev.211根因审计/owner gate与late-promotion回归测试，版本提升到`0.31.0+211`。

## 0.31.0-dev.210：版本映射预热、Reader 快速恢复与 verified partial 复用

- 结合 01:09 真机 trace 与 VibeVenera 参考实现确认 dev.207–209 把 source request-plan page identity 验证放在 Reader 前置 await：Home 首帧约1.07s后直到约13.96s才完成 alias preparation，Reader约14.08s才创建；Reader创建后约0.27s即首帧。
- confirmed version relation 新增按章节持久化 `ComicVersionPageMapping`（章节ID、页数、verified offset、验证时间），SQLite schema升至8并提供v7迁移；详情页和Reader只异步刷新版本/强identity mapping。
- Reader关键路径只从 durable relation/page mapping 恢复现有 promoted artifact alias，不再调用 `verifiedPageReuseIdentity`/source request-plan；无mapping时直接正常进入Reader，后台预热供后续复用。
- verified mapping下支持 durable inactive partial 前缀复用；不碰hot DownloadSession，跨版本validators清空，真实续传继续由DownloadJob validatorless Range overlap逐字节验证。
- source card更新判断按 predecessor/successor canonical identity匹配confirmed relation，不再因alias集合包含successor而吞掉旧版`!`；首次入架继续清理陈旧章节`sourceUpdateAt`，版本relation不镜像该字段。
- 新增 ADR 0191、dev.210根因审计/owner gate与storage/reuse回归，版本提升到`0.31.0+210`。

## 0.31.0-dev.209：删除版本更新旧 reconcile 残留调用并闭合发布门禁

- 修复 dev.208 编译错误：`demo_home_source_migration.dart::_loadSourceVersionState()` 仍调用已删除的 `_reconcileConfirmedSourceUpdateSignal`。该调用是 dev.207“版本 relation 镜像到 `sourceUpdateAt`”旧路径的半删除残留，直接移除，不恢复旧方法。
- dev.208 ownership gate 从“禁止旧方法定义”加强为“迁移生产代码中禁止该符号出现”，并新增 dev.209 closure gate；`tool/check.sh` 正式接入 dev.209 gate，缺少 Dart/Flutter SDK 时也能阻止同类半删除接口交付。
- dev.208 的 Home relation projection、双向 artifact alias、纵向 ratio-anchor 修复均保持不变；版本提升到 `0.31.0+209`。

## 0.31.0-dev.208：版本关系投影与双向 artifact reuse 收口

- 修复dev.207旧版右上`!`仍缺失：confirmed version relation正式进入`HomeLibrarySession`同步投影，source browser/Home不再依赖详情页把版本关系镜像成`SavedComicRecord.sourceUpdateAt`；章节更新与版本更新保持两个独立事实源。
- `ComicVersionRelation`记录首次`discoveredAt`，SQLite重复确认relation只更新标题、不刷新发现时间；Home更新排序可直接合并章节`sourceUpdateAt`与版本`discoveredAt`。
- 修复新版缓存→旧版不能复用：版本artifact matcher同时消费predecessor与successor relation，版本方向不再决定alias方向；只在相关版本真实artifact已存在且target缺失时注册target→最终storage alias，并避免形成反向alias环。
- 新增Home relation projection、SQLite all-relations、双向offset reuse与alias-cycle回归，以及dev.208 ownership gate；版本提升到`0.31.0+208`。

## 0.31.0-dev.207：同源版本更新提醒、临时 artifact alias 与纵向 anchor 收口

- 修复旧版卡右上更新感叹号缺失：confirmed successor/version 是持续 relation事实，不再只在“本轮首次发现”时推进 `sourceUpdateAt`；已持久化 relation即使早于入架或本次版本查询失败，也可重建书架漫画的 update signal。
- 参考 VibeVenera 临时 key mapping，但复用 ZIC 既有 `ArtifactCacheManager.alias` owner：查看/进入已确认同源新版 Reader 前，先用 source-owned request plan解析首/中/末强媒体 identity，证明页面offset后把新版精确 DownloadId临时映射到旧版已存在 artifact；不迁移、不复制、不 rekey durable library state。
- Venera/E-Hentai opaque `venera-resource:` locator 的复用 identity通过既有 `ComicSourceResourceGateway → source transport request-plan`解析，不增加第二网络/缓存路径；只接受 `/s/<image-key>/` 或32–64位内容hash等强 identity。
- 纵向静态阅读取消 `pageAspectRatios` 异步变化触发的 top-anchor post-frame `jumpTo`，避免用户上下滑动时被比例收敛拉回；vertical stitch、真实 viewport/DPR变化和显式导航仍保留 anchor。
- 新增 dev.207 ownership gate与 artifact reuse回归测试；版本提升到 `0.31.0+207`。

## 0.31.0-dev.206：Download owner partial 收口与 Venera resolver rhttp 统一

- 纠正 dev.205 的 partial ownership：普通 Reader detach/reentry 继续复用 retained `PipelineReaderSession` 内同一 DownloadRegistry/DownloadSession/DecodeSession，不再在 route retain 时 checkpoint；只有 session 真正 dispose/evict 时，unfinished prefix 才由 Download-owned `PartialDownloadHandoff` 交给 `PersistentChapterDownloadService`。`ArtifactCacheManager` 回到仅负责 promoted immutable artifact，消除 dev.205 `ArtifactCacheBackend` partial capability 编译错误。
- 保留 dev.205 decode cursor-reentry 修复与 ZIC 特有的 partial/约30帧循环能力；30帧水位/循环只属于 DecodeSession/playback，不参与 durable cache、网络 resume 或 Download owner 选择。
- Venera `Network.*` resolver 的实际 HTTP 从 Kotlin `HttpURLConnection`/旧 DoH+reflective OkHttp fallback 迁到 isolated plugin Dart process 的 reusable rhttp/reqwest client。Kotlin/WebView继续拥有同步 JS contract、Cookie、manual redirect、`cache-time`、`prevent-parallel`与requestId grouping，但不再拥有第二HTTP连接池；最终 media replay 与 resolver 现在统一 client family，因进程隔离仍各自维护 owner-local reusable client instance。

## 0.31.0-dev.205：Reader partial durable handoff 与 decode cursor 重入

- 12:24 真机trace确认两类长期 partial 生命周期缺口：新 Reader session 的 current 以 committedLength=0 从 origin 重下，而相邻已 promoted 页面可直接从 persistent artifact 命中；未 promoted partial此前只活在短期 Reader session/workspace，真正 dispose 后没有 durable owner。
- 新增独立 `PartialDownloadStore/Handoff`，复用现有 `PersistentChapterDownloadService` 的 DownloadRegistry/Artifact/CacheIndex 保存精确 DownloadId 的未完成前缀、validators 与 totalLength；partial 不进入 promoted immutable cache，也不建立第二个 Reader/App cache owner。Reader retain 异步 checkpoint，最终 dispose 再 drain；下次 session 在网络前恢复。
- 修复 Animated WebP 重入黑屏：holder 已空且要求 cursor restart 时，必须先释放旧 cursor/旧 later-frame `requiredSourceLength`，再做 partial prefix gate；现有 playable partial 可立即从 frame0 重建，而不是等待 full-body catch-up 超过旧 frame25 hint。
- 明确网络边界：最终 media host replay 已由 rhttp 统一；Venera `Network.*` resolver bridge 目前仍是 plugin-host `HttpURLConnection` source-owned client，这是未完成的 client consolidation 债务，不是第二 scheduler。dev.205 不在 partial 修复中混做跨 runtime transport 迁移。

## 0.31.0-dev.204：部分恢复 Headroom Retention，并复用 Venera Resolver HTTP 连接

- 11:48真机trace确认dev.203典型首帧已恢复，但request-plan cold miss仍是尾延迟主因；用户指出dev.203对dev.202 retention回滚过度。NetLane现取1/3 bounded + 2/3 headroom固定插值，相对dev.202只回滚约1/3；admission priority与1000 current安全margin不变。
- Venera `Network.*` bridge的正常完整HTTP response不再无条件`disconnect()`：显式关闭InputStream后允许平台HTTP/1.1连接池复用；异常/requestId取消仍物理disconnect。cache/cookie/header identity、single JS invocation与Reader/Pipeline ownership不变。

## 0.31.0-dev.203：bounded restart-cost retention rollback

- 真机反馈显示dev.202体感较dev.201退化；对照Trace中典型首帧中位未恶化，但最坏尾部由约2.86s扩大到6.84s，主导为current sourceWait/request-plan/host-open。
- 撤销dev.202的base→current-safe headroom投影，精确恢复dev.201时间最多+60/流量最多+40的bounded restart-cost victim bonus；admission priority、restart-cost事实与downloadPreempted观测保持。
- dev.202 ADR标记Superseded；Venera source-plan/host-open冷尾延迟单独记录，dev.203不混改第二条因果链。

## 0.31.0-dev.202：restart-cost headroom retention

- dev.201固定最多+100的victim bonus改为0..1 restart-cost score占据base→current-safe ceiling的剩余rank空间，修复logical detach降base=0后高重做成本仍几乎无保护的问题。
- 时间/流量仍分别用5s/4MiB指数饱和，0.60/0.40仅作为成本权重；不读取网速、endpoint、decode/playback或Trace派生字段。
- pending/admission priority保持不变，1000 current继续保留40点preemption margin；新增base=0真实成本回归场景。

## 0.31.0-dev.201：restart-cost retention victim ranking

- full-body成本控制从开始前admission扩展到开始后的preemption economics：不可恢复response已投入wall time与consumed bytes只提升active victim retention rank，不提升admission priority。
- NetLane使用5s/+60与4MiB/+40的连续指数饱和bonus，并以current-safe cap保证1000 current始终保留40点preemption margin。
- DownloadJob只报告restart-cost事实；普通Range resume、endpoint hash、HTTP version、网速与decode/playback状态不参与retention policy。
- 新增`downloadPreempted` Trace，记录实际preemption时incoming/base/retention rank、bonus与restart-cost事实。

## 0.31.0-dev.200：defer跨demand记忆与very-large partial两级成本

- 08:46 dev.199真机trace中45条origin body约245.59MiB，重复前缀约40.96MiB（16.68%）；6次strong-validator Range继续206/direct/duplicate=0。dev.199低priority defer已能阻止full body，但同一5.43MiB page在三个独立780 demand窗口仍重复probe→200→defer，11.95MiB page也出现两次，说明defer随tracking retire被遗忘。
- `_downloadDeferred`改为`DownloadId -> committedLength`：idle partial未增长时，低priority demand完整detach/re-add仍保持defer，不再重新联网；partial增长、成功/promotion/dispose或priority达到当前成本门槛时清除并重新probe。它不是endpoint能力，不写入disk。
- full-body admission改为两级：1–8MiB partial仍允许next=820；>=8MiB very-large partial必须transition/current的>=900。当前trace中820路径约18.86MiB重复里，单个9.14MiB partial的abort+完成贡献约13.57MiB；该路径在dev.200会等到900+再承担整段重读。
- DownloadJob Range/CRC continuity、DownloadSession playable authority、Reader/Pipeline、NetLane/network=5、Venera/Mihon与endpoint diagnostics均不改变。新增ADR0181、dev.200 audit/gate与detach/re-add、8MiB两级行为回归。

## 0.31.0-dev.199：大 partial 的成本感知 full-body catch-up admission

- 07:51 dev.198 trace 中 strong-validator Range 仍保持 direct 206 且重复前缀为0，但服务器忽略 Range 后的 full-body catch-up 再次把重复前缀推高到约19.2MiB/123.2MiB（15.6%）；多数高成本 fallback 在 priority 760/780/800 的背景或邻近预取角色启动。
- sessions 现在只对“必须 full-body 且已保留 partial >=1MiB”的高重启成本路径增加 admission：动态 TaskControl priority <820 时保留 artifact/Ingress 并 defer，不读取 full body；priority 升到 next/visible/current 的 >=820 后由同一 LiveCoordinator 重新提交。小于1MiB的 partial 继续允许背景 catch-up。
- Range probe 本身仍允许，且不持久化“endpoint不支持Range”能力：低优先级首次 probe 返回200后 defer；升到820+后重新 probe，若路由/endpoint 已能206则直接Range续传，否则复用同一个200 response做dev.196既有 full-prefix CRC catch-up。defer不建立第二个scheduler、不改变network=5/Reader窗口/播放authority，也不读取endpoint hash、`duplicatePrefixBytes`等诊断形成policy。
- 新增 ADR0180、dev.199 root-cause/validation audit与 DownloadJob/LiveCoordinator 回归契约；`tool/check.sh`同时补回既有dev.198 gate并加入dev.199 gate。

## 0.31.0-dev.198：product-safe rhttp endpoint 观测与显式 receive-progress 诊断构建

- 06:36 dev.197 trace已缩到约1.27MB/3287 events；可归账origin body约101.6MiB，`duplicatePrefixBytes`约4.32MiB（4.25%）。2次strong-validator resume仍为direct 206；剩余重复来自服务器忽略Range后的full-prefix fallback。current=1000的Venera gate wait中位接近0，且body并发越高聚合吞吐仍上升，因此不降低network=5、不新增current独占带宽。
- 普通product/release现在始终记录每个rhttp response一次的HTTP version、匿名remote-IP hash和`sourceRhttpReceiveProgressEnabled`；这些低开销字段用于按endpoint分组CDN差异，不进入policy。
- 高频`onReceiveProgress`仍默认不在product/release注册；`tool/build_android.sh`新增`ZIC_RHTTP_RECEIVE_PROGRESS_DIAGNOSTICS=1`显式诊断开关，仅在需要比较native receive与Dart body delivery时附加dart-define。
- trace analyzer新增匿名endpoint hash计数。rhttp raw cadence、DownloadJob 16/64KiB单一aggregation、Range/resume、playable partial、Reader/Pipeline与NetLane全部不变。新增ADR0179、dev.198 audit/gate。

## 0.31.0-dev.197：Debug Trace 语义导出压缩与流式过滤

- 05:28 dev.196真机trace共5502条、约1.79MB；Range continuity已经把可归账origin body中的重复前缀压到约2,996,334/177,601,680=1.7%，3次strong-validator resume均direct 206。剩余最大重复来自服务器忽略Range后用户远跳，旧catch-up随detach迅速取消，因此本轮不扩大NetLane/下载状态机。
- App Debug Trace只在export projection把高频`framePipelineTiming`与`decodeRefill`按稳定语义桶合并；保留first/last/coalescedCount以及关键timing/source length/revision的min/max。错误、retry/resume、`sourceRead`、download lifecycle/priority等权威边缘继续逐条导出，运行时Trace生产与policy不变。
- 新增流式`tool/filter_debug_trace.py`，支持`network/playback/failures/all` profile与identity/session筛选；处理大JSONL时不把整文件加载进内存。按05:28 trace实测，network profile从约1.79MB降到约476KB。
- 新增ADR0178、dev.197 root-cause/validation audit、导出语义回归与filter工具测试；不改DownloadJob/DownloadSession/DecodeSession/Reader/Pipeline/NetLane、Range策略或带宽策略。

## 0.31.0-dev.196：validatorless Range continuity probe，消除 full-prefix 重复流量常态

- dev.195 真机03:12 trace的36条origin body约182.70MB，其中12次full-body prefix catch-up至少30.20MB（16.5%）只是在重新验证已存在partial；一张14.59MB页面实际从origin读取27.74MB。
- 根因有两层：dev.195在validators为空时主动不传Range；同时production rhttp direct对合法206中段仍做完整图片magic-prefix检查，中段不含文件头会误触发runtime fallback。dev.196在已知totalLength的validatorless partial上先请求最多64KiB尾部Range，并让rhttp对`Content-Range.start>0`跳过完整媒体头检查；只有精确206/start/length和逐字节overlap一致才从旧boundary继续。
- Range被服务器忽略并返回200时直接复用该response进入现有full-prefix CRC fallback；strong-validator Range被200拒绝时也复用同一body，不再仅为fallback再开第二条full request。
- `resumeAccepted/resumeRestarted`新增只读`resumeProbeStart/resumeProbeBytes/resumeProbeStatusCode/resumeProbeAccepted/duplicatePrefixBytes/fullBodyResponseReused`观测；不得成为调度、retry或cache输入。
- dev.195的playable-partial单调性、幂等Ingress restore保持；不改DecodeSession、Reader/Pipeline、NetLane、network=5或带宽策略。新增ADR0177、dev.196审计与gate。

## 0.31.0-dev.195：从 dev.192 重做 partial authority，网络重启不得让可播放数据倒退

- 明确废弃 dev.193/dev.194 的续传实验线；dev.195 直接从权威 dev.192 ZIP 重做，不 cherry-pick 后两轮 overlap/catch-up 或 DecodeSession 修改。
- 修复 dev.192 的基础生命周期错误：无 validator、Range 被拒绝或 resume fallback 不再 `session.reset()` 已有 partial。网络可从 byte 0 重新读取完整响应，但旧 artifact/Ingress 保持可播放；收到的 `[0, oldCommittedLength)` 完整 CRC32 与现有权威 partial 一致后，才从旧 boundary 继续 append。catch-up mismatch/取消/提前EOF只失败当前 attempt，不删除旧 partial。
- `DownloadSession.restore()` 若当前 Ingress 的 epoch/length/kind/sealed 已与 artifact 一致则不重建 native encoded source；网络 task 重启不再顺带重启播放器 source。损坏/缺失 resume metadata 只清除 validator/total-length 知识，除明确 DownloadId owner mismatch 外不删除 committed media。
- 不修改 DecodeSession、Reader/Pipeline、NetLane、network=5、1000/780、7/3/2/1/7/5/3/2，也不新增 bandwidth scheduler 或 rhttp transport framing。新增 ADR 0176、dev.195 root-cause audit/gate。

## 0.31.0-dev.192：rhttp 持续传输分段观测，不提前增加带宽调度

- `zic-debug-trace-2026-08-09T15-08-46.jsonl`确认dev.191 resolver cache明显生效：16个已结束origin read中cache hit中位3、origin resolver call中位1，hook中位约0.393s、host-open中位约0.433s；剩余长尾移到最终图片body，stream中位约3.004s、p90约9.428s，且存在近似单流仍约0.42MiB/s的慢样本。
- 当前origin body没有ArtifactCacheReadScheduler字节配额或其它bandwidth scheduler；NetLane只拥有admission/concurrency/preemption。current=1000并不稳定获得最高持续吞吐，但单流慢样本说明不能据此直接新增current带宽token bucket。
- rhttp direct bridge新增纯观测分段：使用rhttp `onReceiveProgress`记录receive-progress，并在最靠近`HttpStreamResponse.body`边界记录raw body event；`ByteResponseReadDiagnostics`只在现有`sourceRead`结束/取消时snapshot。新增HTTP version、匿名remote-IP hash、progress/body event/gap/chunk及progress领先body字节等字段，用于区分源/CDN/rhttp接收慢与Dart body交付/backpressure。
- 不恢复64/256KiB transport framing、不改变DownloadJob 16/64KiB单一aggregation、不新增Reader/Pipeline带宽scheduler。`sourceRhttp*`继续只读并由dev.192 gate禁止进入sessions/pipeline_runtime/App policy。新增ADR 0175与dev.192 audit。

## 0.31.0-dev.191：补齐 Venera source-requested Network Cache 语义

- `zic-debug-trace-2026-08-09T14-12-27.jsonl` 的18个origin样本显示：request-plan中位约3.016s，其中gate wait中位约1.742s、hook中位约1.392s、hook内部bridge network中位约1.368s；18/18页都恰好执行4次bridge network。一个host-open 17.424s异常样本属于真实网络长尾，但整体结构性瓶颈在plan resolver。
- 对照当前 Venera E-Hentai source 与 Venera Network实现确认：`loadThumbnails`/`getKey`显式依赖`cache-time: long`与`prevent-parallel: true`，但ZIC native bridge此前把这两个控制字段当普通HTTP header发送且完全忽略cache语义，导致每张图重复执行本应复用的gallery/key GET；单JS invocation再把重复resolver串成gate阶梯。
- `VeneraNativeBridge`现在实现runtime-owned、source-requested GET cache：`long` 6小时、短命中5秒、单entry<1MiB、总量10MiB；cache identity比较真实请求headers并保留Cookie差异，命中响应标记`venera-cache:true`。`cache-time`/`prevent-parallel`只作为Venera Network控制字段，不发送给origin；当前单invocation已经提供比same-path prevent-parallel更强的物理串行保证。该cache不进入Pipeline/artifact/Reader所有权。
- source-plan diagnostics新增`sourcePlanBridgeNetworkCacheHits/sourcePlanBridgeNetworkOriginCalls`，用于区分4次逻辑`Network.*`调用中真正出网与runtime cache命中；字段继续只读，不得成为scheduler/cache/retry policy输入。新增ADR 0174、dev.191 audit/gate与可执行Kotlin cache helper contract。Reader固定7/3、2/1、7/5/3/2、network/decode/upload 5/3/2、previous780/current1000均不变。

## 0.31.0-dev.190：Runtime Resource-Plan Timing 编译闭环与耦合收口

- 修复 dev.189 `runtime_source_adapter.dart` 的真实编译错误：session 私有 `_invoke` 新增 `onTiming`，但 `_RuntimeBrowsableComicSource` 持有的 `_RuntimeInvoke` typedef 未同步，导致经函数类型调用 `onTiming:` 时编译器报“no named parameter”。
- 不把 `onTiming` 扩散到通用 runtime invoke 契约。普通 browse/details/account 调用继续只依赖 `_RuntimeInvoke`；resource-plan 单独注入 `_RuntimeResolveResourceInvoke`，由 session 内部 `_invokeMeasured` 返回 payload + gate/runtime timing，再由 source adapter 合并到 `ComicResourceRequest.diagnostics`。删除 callback 式 `onTiming` 半迁移面。
- 收口 observability 耦合：`sourcePlan*` 只允许沿 plugin_host → downloads trace 透传，不允许进入 sessions、pipeline_runtime 或 App policy；新增 dev.190 静态 gate 防止 diagnostics 变成第二调度通道。Reader/Venera 调度参数与 dev.189 行为均不变。

## 0.31.0-dev.189：Venera Current-Only 动态抢占与 Plan Stage 分段

- 对照 dev.187/188 真机trace确认 dev.188 体感退化主要是 request-plan tail 放大而非最终图片网络：plan p90约5.421s→9.353s、max约6.935s→12.330s；host-open中位仅约0.331s→0.399s，p90反而下降。
- supersede ADR 0171 的过度动态触发：保留首次previous=780 pressure与实时priority permit排序，但进入gate后的priority变化只有waiter真正跨入current=1000时才重新触发preemption；780↔900 transition jitter与active invocation demotion不再造成不可逆plan cancellation。单Venera invocation、真实`finished(requestId)`后才转交permit均不变。
- 新增只读source-plan stage diagnostics：Dart gate wait/runtime invocation、JS hook、hook内部bridge network耗时/调用数，并继续与host-open分离；命中transport request-plan cache时不复用历史hook耗时。diagnostics明确禁止成为scheduler/retry/cache输入。
- Node Venera bootstrap新增request-scoped bridge-network timing行为验证；补Dart owner tests与dev.189 gate。Reader固定7/3、2/1、7/5/3/2、network/decode/upload 5/3/2、previous780、current1000、reserved1、threshold40均不变。

## 0.31.0-dev.188：Venera 动态 Priority 传播与 Request-Plan 取消边界澄清

- `zic-debug-trace-2026-08-09T11-04-46.jsonl`确认 dev.187 后 source request-plan仍是主要长尾：21个 origin 样本的 `sourceRequestPlanMicros` 中位约3.467s；更关键的是已有 NetLane task 在等待 Venera 单invocation gate 时可从previous 780升到transition 900再升到current 1000，但 gate此前只在首次入队时判断preemption，后续实时priority变化不会重新触发比较。
- `TaskControl`新增scheduler-owned可选 `PriorityObservableTaskControl`；`NetLane.CancelToken`在active same-key原位迁移时发出priority change，Venera gate只订阅该信号并重新比较现有waiter/active invocation，仍无权设置rank或建立第二调度器。queued waiter升级和active invocation降级都会重新执行既有floor=780、差值>=40的controlled preemption规则；真实`finished(requestId)`前仍不释放唯一permit。
- 明确Venera取消边界：`loadEp`产生章节/page identity，per-image `onImageLoad`可异步生成request plan；最终图片body由`SourceResourceTransport`在native host transport执行。`__zicCancel(requestId)`只标记/打断JavaScript request-plan invocation及该hook通过bridge发起的request-scoped工作，不拥有后续最终图片HTTP。没有整章预解析`onImageLoad`，避免把按需resolver变成全章网络前置。
- 新增动态priority行为回归、NetLane priority signal回归、ADR 0171、dev.188 audit/gate；固定7/3、2/1、7/5/3/2、network/decode/upload 5/3/2、previous780、current1000、reserved1、threshold40均不变。

## 0.31.0-dev.187：Venera Request-Scoped Cancel 物理闭环

- `zic-debug-trace-2026-08-09T10-30-21.jsonl`用 dev.186 新分段观测确认剩余 origin-open 长尾主要不在 host HTTP open：18个 origin 样本的 `sourceRequestPlanMicros` 中位约3.195s、`sourceHostOpenMicros` 中位约0.367s，request-plan 占总 `readMicros` 的中位比例约83%。因此不再调整 NetLane 780/1000、network=5、current +1 或 decode/upload。
- 大跳页样本中，旧 previous 在30.733s已进入 request-plan，31.459s 离窗后按 queued/pre-open 路径取消；新 current 在31.460s立即以5+1 handoff进入 NetLane，但其 request-plan仍耗时约3.447s，到35.894s才取得 origin response。外层 admission 已及时，剩余 owner 是 Venera requestId cancellation 到唯一 JavaScript invocation 真正 finished 的物理 unwind。
- 只读对照 VibeVenera 后发现 ZIC bridge 的 `delay` 仍由 native `Thread.sleep` 同步阻塞，而 VibeVenera 使用异步 delayed Future；同时 ZIC request-scoped cancel 集合此前只登记 HTTP connection/call，不登记正在阻塞读取的 response `InputStream`。前者是不可抢占 bridge wait 风险，后者是明确缺失的 body-read abort seam。
- Venera bootstrap 现在在 JavaScript 侧用 WebView 原生 timer 实现 request-scoped async delay，`__zicCancel(requestId)`会清 timer 并 reject 对应 Promise；native bridge不再允许 blocking `Thread.sleep` delay。URLConnection 与 DNS-fallback 的 response `InputStream`也登记到同一 requestId cancellation 集合，preemption 时主动 close；单 JavaScript invocation、真实 `finished(requestId)` 才释放 permit 的规则保持不变。新增 ADR 0170、dev.187 audit/gate，版本提升到`0.31.0+187`。
- 顺手修正两个继承的历史静态gate而不改变生产语义：dev.160不再把source-owned runtime fallback绑死在旧`return _openRuntimeFallback(`语法；dev.186不再要求当前状态/交接文件仍停留在dev.186，只继续冻结ADR 0169、stage diagnostics与版本下限。

## 0.31.0-dev.186：Venera Previous Request-Plan 压力与 Source-Open 分段观测

- `zic-debug-trace-2026-08-09T10-05-26.jsonl`确认 dev.185 外层 previous admission 已基本收敛：5个可完整匹配的660→780到`downloadStarted`样本仅3.1–14.4ms，中位6.508ms；不再修改NetLane 780/1000、network=5或current +1。
- 剩余长尾位于 origin open：按`downloadStarted` rank分组，1000/820/800/780 到origin response的中位约2.41/3.27/6.17/5.13s。Venera单invocation gate此前只有current=1000可主动preempt低rank request-plan work。
- Venera gate改为 controlled pressure floor=780，并继续要求40分差值、单次preempt request和旧JavaScript `finished(requestId)`后才转交唯一permit；previous不能制造第二个JS context。
- `ByteResponse`新增只读diagnostics，source transport拆出`sourceRequestPlanMicros/sourceRequestPlanCacheHit/sourceHostOpenMicros/sourceOpenPath/sourceRetryUsed`并透传到origin trace；仅增强观测，不改变retry/cache/framing。新增ADR 0169、dev.186 audit/gate，版本提升到`0.31.0+186`。

## 0.31.0-dev.185：Adjacent Previous 普通槽压力抢占

- `zic-debug-trace-2026-08-09T09-43-55.jsonl` 验证 dev.184 的 receiving 判据修复有效：current 多次在提权后约 0–44 ms 内进入 `downloadStarted`；但 previous=780 仍可在普通槽饱和时等待约 1.866 s，另一次在整个 previous 阶段都未启动，直到后续升级为 current 才借 current-only handoff 运行。
- 剩余根因位于 `NetLane` admission：priority 780 的 previous policy 正常生成，但只有 current/high-priority 阻塞任务能触发 active victim preemption；priority 0 retained receiving 或 740/760 speculative active work可长期占满 normal 5 slots。
- Reader network lane 新增 `pressurePreemptionPriorityFloor=780`：被普通槽阻塞的 previous/更高 in-window normal work在与 victim 差值至少40时可请求取消一个更低 rank active task，但绝不借 current 的 max+1 handoff，必须等待 victim 物理退出后才进入原 normal slot；current=1000 的 bounded handoff 保持不变。
- receiving detach仍优先保留原连接：没有真实窗口压力时继续 priority 0运行；只有 adjacent previous 或更高 normal pressure真实等待时才让出槽。新增 NetLane normal-pressure 与 LiveCoordinator retained-receiving→previous 回归；固定7/3、2/1、7/5/3/2、network/decode/upload 5/3/2、current1000、previous780、reserved1、threshold40均不变。新增 ADR 0168、dev.185 根因审计与 release gate，版本提升到 `0.31.0+185`。

## 0.31.0-dev.184：按真实 Receiving 生命周期释放旧槽并恢复 Previous 交棒

- 根据 `zic-debug-trace-2026-08-09T08-58-13.jsonl` 区分 policy 与 execution：previous demand 会按 priority 780 正常生成，但一次 16→17/17→16 邻接切换中，previous 从提权到真正 `downloadStarted` 等待约 3.00 秒；同时 trace 出现 `receivingRetained=false` 后同 identity 仍被迁到 `retained-background=0` 的矛盾。
- 根因是 `LiveCoordinator` 用 `DownloadSession.activeRun` 近似 receiving；run lease 在 restore、source request-plan、Venera gate 与 HTTP open 之前已经成立，导致尚未建立 writer/字节接收的离窗任务也被长期保活并占 NetLane / Venera 执行资源。
- logical detach 现在只保留真实 `DownloadState.receiving` 且仍为 NetLane active 的任务；active 但 queued/opening 的任务沿既有 `TaskControl` 调用 `net.cancel()`，等待物理 transport 退出后释放 permit；纯 queued 任务继续 `cancelQueued()`。不新增调度器，不改变 encoded 7/3、decode 2/1、holder 7/5/3/2、normal lanes 5/3/2、current 1000 或 previous 780。
- 新增“receiving detach 保持原连接”和“pre-open detach 取消后 adjacent previous 获得唯一网络槽”回归；新增 ADR 0167、dev.184 根因审计与 release gate，版本提升到 `0.31.0+184`。

## 0.31.0-dev.183：Current bootstrap、执行保留槽与 Venera 物理抢占

- 根据 `zic-debug-trace-2026-08-09T08-12-07.jsonl` 纠正首帧根因：首帧解码通常仅几十毫秒，但 policy 经常同时生成约7个 static warm decode 与4–7个 upload；ZIC只有network有current handoff，decode/upload可被预取占满。
- 对齐 VibeVenera：动态current浅水位先到最多3帧，静态current一帧；bootstrap期间 speculative next/next2/previous停止实际refill。far static不再越过前2/后1稳定decode窗口，真实viewport静态页保留一帧输出资格。network/decode/upload均新增current-only +1 handoff，normal并发仍5/3/2。
- 修复Venera抢占的物理生命周期：native cancel先按requestId断开旧HTTP，但不再立即完成Dart invocation；只有旧WebView JavaScript真正`finished`后才返回cancelled并释放唯一runtime permit，避免旧/新async调用重叠并污染全局request identity。
- 修复dev.182 `ArtifactCacheReadLease?` nullable访问导致的实际编译错误；新增current-bootstrap/lane/Venera物理退出回归和dev.183 release gate。

## 0.31.0-dev.182：移除 rhttp 双重 framing，恢复 DownloadJob 单一聚合 owner

- 根据 `zic-debug-trace-2026-08-09T05-38-39.jsonl` 确认 dev.181 production control propagation 已生效：origin 已出现 `controlledFallback=true`，current 可携带 priority 1000 到 cache read-through 后的 source path；慢页仍由约 2–16 秒 `sourceWait` 主导，native decode 通常只有几十毫秒。
- 重新只读对照权威 `vibevenera-master.zip` 后确认，VibeVenera Reader 的 `streamOnly` 媒体路径直接转发 rhttp stream；其 64 KiB/256 KiB coalescing 属于非 direct-stream 分支。dev.179 把该 framing 错迁到 ZIC production rhttp transport，叠加了 `DownloadJob` 已有的 16 KiB startup / 64 KiB source-progress aggregation。
- 删除 `RhttpChunkCoalescer` 及其独立回归；`RhttpSourceResourceDirectTransport` 通过媒体前缀验证后保持 raw streaming cadence，chunk aggregation 唯一属于 `DownloadJob`。这样仍阻止约 1–2 KiB packet 逐个进入 native/artifact，同时不再额外等待 64/256 KiB transport buffer 才产生 source growth。
- dev.181 TaskControl read-through、Venera single-invocation priority、rhttp cancellation、retained receiving、7/3、2/1、5/3/2 全部保留；不引入整章 request-plan 预解析。新增 ADR 0165、dev.182 根因审计和 release gate，版本提升到 `0.31.0+182`。

## 0.31.0-dev.181：修复生产 Artifact read-through 丢失 current TaskControl

- 新 trace确认 cache/hot页面已可十几到数百毫秒首帧，但origin current即使已以priority 1000进入NetLane 5+1，仍可在`source-loader`等待约8秒；response可用后首帧只需约百毫秒。
- 根因是生产`PipelineReaderSession`始终把`ArtifactCacheTransport`作为最外层transport，而该wrapper仅实现普通`Transport`；`DownloadJob`因此不调用controlled入口，cache miss又无条件`fallback.open()`，dev.175–177建立的TaskControl在进入Venera前被read-through层擦除。
- `ArtifactCacheTransport`现实现`ControlledTransport`，普通open委托controlled入口；cache miss向controlled fallback原样传递同一个TaskControl，并在cache/origin边界保持cancellation权威。origin trace新增`controlledFallback`和priority。
- 对照当前VibeVenera确认其同样在单图下载附近解析image-loading config，因此本轮不引入整章request-plan预解析，不修改7/3、2/1、5/3/2或rhttp framing。
- 新增ADR 0164、dev.181根因审计、行为回归和release gate。版本提升到`0.31.0+181`。

## 0.31.0-dev.180：OpenJDK 25 构建环境与 Previous/Last 角色解耦

- 根据 `zic-debug-trace-2026-08-09T04-18-30.jsonl` 定位跳页后 previous 不预下载：current 104→105 时旧 current 的 download 从 priority 1000 直接降为 retained-background 0；`RoleResolver` 同时把旧 current写成独占 `last`并从 backward window跳过，于是 immediate previous 104 被吞掉，103错位成为 priority 780 的 previous。
- 对照权威 VibeVenera窗口语义，将“保留上一张已上传 output”从相对 page role中拆出为 `retainedIndex`：相邻旧 current仍按 offset -1/-+1参与 previous/next download/decode，同时叠加 upload-only `last` retention；大跳页后旧 current若离开7/3窗口则只保留 output，不产生冗余 download/decode。
- 按用户本地 Flutter 3.44 resolver证据把 workspace直接 `test` 约束改为 `^1.25.0`，避免 `^1.31.2`强迫不兼容的 `test_api 0.7.13`；不手工改 lock，仍由本地 `flutter pub get` 权威解析。
- 恢复用户已验证构建链 AGP 9.3.1 + Gradle 9.5.0 + compileSdk 37；Gradle daemon criteria改为 OpenJDK 25。Android Java/Kotlin产物仍 target 17：构建JDK与class-file target分离，避免仅因开发机JDK25就抬高Android运行时要求。
- ADR 0162 的工具链部分由 ADR 0163取代；rhttp 0.18.0、64KiB/256KiB framing与Built-in Kotlin迁移准备继续有效。版本提升到 `0.31.0+180`。

## 0.31.0-dev.179：稳定工具链升级与 rhttp 流量整形

- 根据 `zic-debug-trace-2026-08-09T02-48-10.jsonl` 继续拆首播：25条 origin source read 的 `openMicros` 中位约6.20s、p90约8.11s；rhttp 已进入生产路径，但一张15.64MB媒体被直接上抛为10,713个约1.2–1.46KB小包，造成 Dart Stream/commit/artifact/native/status高频调度。
- 对照权威 `vibevenera-master.zip` 补齐 rhttp stream framing：通过前16字节媒体校验后，首个逻辑块聚合到64KiB、后续聚合到256KiB再交给 DownloadJob，尾块完整刷新；不改变7/3、2/1、5/3/2、NetLane/TaskControl、artifact或重试所有权。
- rhttp 升至0.18.0；全workspace最低环境提升至 Dart 3.12 / Flutter 3.44，并把直接 Dart依赖更新到当前兼容稳定版本。`plugin_host_bridge`同步更新 Gson 2.14.0、kotlinx serialization/coroutines 1.11.0和测试 `org.json` 20260522；Mihon ABI SHA/Injekt/QuickJS/RxJava1及兼容编译器/stdlib继续按extension ABI固定，不做机械升级。
- Android构建链固定在兼容稳定 AGP 9.1.1 + Gradle 9.3.1 + compileSdk 37 + JDK17；新增 daemon JVM 17 criteria。五个本地Flutter Android插件移除自行应用KGP与legacy `kotlinOptions`，改用 `kotlin.compilerOptions`，为Built-in Kotlin迁移准备；稳定Flutter 3.44阶段仍保留 `android.builtInKotlin=false`，不为消 warning切到3.47 beta。
- 新增 ADR 0162、dev.179工具链/stream-framing审计与release gate，版本提升到 `0.31.0+179`。当前环境无Flutter/Dart，不能重算 `pubspec.lock`；本地首次应用后必须运行 `flutter pub get`。

## 0.31.0-dev.178：VibeVenera Rust Streaming Transport 首播路径

- 根据 `zic-debug-trace-2026-08-09T01-44-16.jsonl` 重新拆分首播延迟：remote current 的 first-frame decode/upload只有几十毫秒，主要时间在 source/request-plan/open 约2–4秒，以及首个约250–300 KiB可解码前缀在5路Dart HttpClient传输下继续等待数秒；cached页仍能在约30–220ms显示。
- 对照权威 `vibevenera-master.zip`：保留 encoded 7/3、decode 2/1、network/decode/upload 5/3/2与 retained-receiving/preemption，不用缩窗口换首帧；把生产 source media HTTP engine迁到 `downloads_bridge` 的 Rust/rhttp streaming transport。
- `downloads` 新增 composition-owned `SourceResourceDirectTransport` 控制面，平台实现必须接收同一个 `TaskControl`且由 transport pool关闭；pure downloads仍保留 Dart HttpClient作为非Flutter/test默认，不依赖rhttp。
- `RhttpSourceResourceDirectTransport` 固定 rhttp 0.13.0以保持 Dart>=3.6；后台预热Rust runtime，复用单一client与60s keep-alive，关闭自动redirect/status throw，保留source headers/body、range/validator、媒体前缀校验、Set-Cookie/source-owned fallback与完整response取消。
- 新增 dev.178 owner gate和 controlled platform transport regression；版本提升到 `0.31.0+178`。由于当前环境无 Dart/Flutter，`pubspec.lock` 无法由 pub重新解析，依赖锁需在用户本地 `flutter pub get` 时生成。

## 0.31.0-dev.177：VibeVenera Retained Receiving、嵌套 Current 抢占与下载管理 Route-First

- 重新只读对照权威 `vibevenera-master.zip`，撤销未冻结的“离开7/3即直接cancel active transfer”候选：receiving transport普通logical detach继续保留并降为priority 0，queued undemanded仍可取消；短时前后切页原位恢复priority，不反复断线/重下。
- 恢复并保留dev.174与VibeVenera一致的bounded saturated preemption：normal5 + reserved1已占满时，新的current仍可推动另一个尚未取消的低rank victim退出，但真实task结束前不释放permit。
- ZIC额外存在Venera单上下文runtime bottleneck：新增pressure-only active invocation preemption。只有scheduler-controlled current(priority 1000)相对低rank active invocation满足门槛时才cancel该runtime request；普通detach不cancel。`runtime-request-cancelled`映射为domain cancelled。
- 下载管理页改为route-first：首帧直接使用Home现有chapter snapshot和whole-comic queue snapshot；durable/cache刷新移到首帧后，并统一使用`inspectMany()`，不再在route首帧前逐章节inspect。
- dev.175 TaskControl/native lock与dev.176 response lifetime abort/CRC off-hot-path均保留；不新增cancel防抖timer或第二套prefetch状态机。
- 新增ADR 0160、dev.177根因审计与release gate，版本保持`0.31.0+177`。

## 0.31.0-dev.176：收口被抢占 Response 生命周期与 Artifact CRC 热路径

- 新 trace确认 dev.175 已把 current推进到 network handoff，但 origin `openMicros`仍出现约5–19秒等待；被取消的 prefetch在 Pipeline已失败后仍可能保留底层 HTTP response。
- source host transport现在把 `TaskControl.whenCancelled`绑定到整个 prefetched response body，async* consumer取消也在 `finally`中 cancel底层 `HttpClientResponse` iterator；Pipeline取消不再只停在 request/prefix阶段。
- 下载卡顿主导项从 dev.175前的 native source锁竞争转为 artifact commit CPU；partial append移除主 isolate逐块 CRC32，seal/restore边界在 isolate一次性校验文件，checksum完整性与promotion语义不变。
- Reader 7/3、decode 2/1、network/decode/upload 5/3/2、reserved current 1均不变。新增 ADR 0159、dev.176 audit/gate，版本提升到 `0.31.0+176`。

## 0.31.0-dev.174：补齐 Current 在饱和 Handoff 下的连续抢占

- 以文件库权威 `vibevenera-master.zip` 只读对照下载调度：两边都保留 network=5、current高优先级、单一 max+1 handoff、active priority migration；关键差异是 VibeVenera在 handoff已占满时仍会让新的 current 请求取消另一个未取消的低优先级 running prefetch，而 ZIC此前会在 eligible过滤阶段直接停止。
- `NetLane` 在没有可立即启动任务时，会选出最高优先级且被 lane/bucket容量阻塞的 current，并继续调用既有 `_preemptLowestRunningFor`；已取消、不可抢占、优先级差不足的 active task仍不会被重复处理。
- 不提前释放取消中的 active permit，也不把临时并发提高到 `max+reserved`以上：被抢占 transport仍必须真实退出后才释放 lane/bucket计数，保持单 writer与连接上限。
- 新增 5+1回归：第一条被抢占 prefetch故意迟迟不退出，第二个 current仍必须继续取消另一条低 rank prefetch，并在真实 permit释放后启动，而不是等待第一条或其它预取自然完成。
- Reader/Pipeline既有 7/3、2/1、7/5/3/2、network5、current1000、reserved1、threshold40 均未修改；新增 ADR 0157、dev.174 audit/gate，版本提升到 `0.31.0+174`。

## 0.31.0-dev.173：恢复通用漫画源迁移并统一同源版本/更新提示

- 漫画源卡片已入书架状态改为左上 `library_books` 书架标志并变暗；`sourceUpdateAt` 作为独立右上感叹号提示，不再使用书签形态冒充书架。
- 恢复详情 AppBar“迁移漫画源”入口与通用目标选择器；跨源可标题搜索/原生 ID，同源只使用来源确认的 `ComicVersionSource/ComicVersionRelationStore`，同一面板提供“查看/迁移”。
- 所有迁移继续统一进入 `ComicSourceMigrationPlan + showSourceMigrationComparison`，只有 exact chapter match迁移阅读状态；同源替换偏好改走 `_savePreference`，避免旧 raw alias继续保持书架状态。
- 已在书架且存在 source-confirmed update的 source card显示右上感叹号；点击时若有确认 successor则直接查看其 exact raw detail，否则打开当前详情。
- 新增 ADR 0156、dev.173根因/语义审计与 ownership gate，版本提升到 `0.31.0+173`。

## 0.31.0-dev.172：修复跨插件 Browse Runtime Protocol 字段漂移

- 根据 `zic-debug-trace-2026-08-08T14-27-09.jsonl` 与错误报告确认 Venera、18comic、roumanwu 均在插件调用前由 Dart `ExternalPluginRuntimeRequest` 校验同步抛出 `FormatException: runtime request arguments do not match operation`；不是三个 source 同时网络失败。
- 修复 dev.171 `useFilters` 协议迁移遗漏：browse typed factory、wire validator 与 adapter payload 现在共同声明 `useFilters`；新请求显式发送 bool，旧 schema v1 请求可缺省并按 runtime 默认 false 解释，未知字段仍严格拒绝。
- `tool/check.sh` 补接 dev.171 gate 并新增 dev.172 runtime-browse protocol gate；在缺少 Dart/Flutter SDK 的环境也会检查 protocol/factory/adapter/Mihon driver 四端一致，避免新增 wire 字段再次漏迁。
- 新增 runtime protocol 回归测试：filter mode round-trip、旧 v1 browse 兼容、非法 `useFilters` 类型与未知字段拒绝。
- 新增 ADR 0155、dev.172 根因审计，版本提升到 `0.31.0+172`。

## 0.31.0-dev.171：收口筛选视图、书架投影与下载完成反馈

- 根据 `zic-debug-trace-2026-08-08T12-41-26.jsonl` 确认 dev.170 WNACG媒体路径无 `taskFailed`，同时发现筛选请求仍以 `sectionId=latest + filterCount` 表达，没有独立“筛选视图”焦点。
- 将筛选激活从 `filterState` 内容拆为独立 request mode：点击“筛选”后直接应用空 override即使用插件 `FilterList` 默认状态，UI焦点切到“筛选”；filter mode不继承 latest/popular section，Catalog cache与runtime payload显式区分 filtered/section请求。
- 漫画源卡片从 Home canonical preference projection读取 `inShelf`；已入书架封面增加书签并变暗，source browser不维护第二套书架状态。
- Home下载右上角勾从 durable chapter cache状态改为显式命令完成反馈：单章节命令完成显示空心勾，整本队列真正 complete显示绿色实心勾；进入详情即消费，任意已缓存章节不再冒充整本/命令完成。
- 新增 ADR 0154、dev.171根因审计与 owner gate，版本提升到 `0.31.0+171`。

## 0.31.0-dev.170：收口 Mihon 明文媒体能力与下载失败重试所有权

- 根据 `zic-debug-trace-2026-08-08T11-55-06.jsonl` 确认 WNACG 目录/详情/章节元数据成功，封面全部 source-load失败，Reader正文则被 Android `CLEARTEXT ... not permitted by network security policy` 在发请求前拒绝；不做 WNACG 域名白名单或 HTTPS改写。
- Android宿主通过统一 Network Security Configuration允许插件/source实际返回的 HTTP(S)媒体 URL；source/request plan继续拥有准确 URL/headers/client，HTTPS来源不受影响。
- external runtime `retryable`错误显式映射为 `ErrorCode.network`；`UnknownServiceException` 等确定性 transport capability/policy错误不再伪装成 transient network。
- `LiveCoordinator` 增加当前 demand内 terminal download failure latch，删除 source-listener 的第二下载重提权；非 retryable失败和网络重试耗尽后不再被 `finally` 热循环重新提交。
- source-card cover Trace补充 domain error code/message；新增 ADR 0153、dev.170根因审计与 owner gate，版本提升到 `0.31.0+170`。

## 0.31.0-dev.169：按 Mihon Filter ABI 收口来源筛选 schema/state

- 撤销 dev.168“所有 Mihon 均 `supportsSearchFilters=true`”错误抽象：筛选入口恢复由 source实际非空 `getFilterList()`决定。
- 将 Mihon Filter转译从 `MihonRuntimeDriver`拆为纯 Kotlin `MihonFilterCodec`；按官方 Filter基类 `isInstance`识别插件自定义子类，不再根据 concrete class simple name猜类型。
- 完整投影 Header/Separator/Select/Text/CheckBox/TriState/Group/Sort，保留 Group层次；runtime筛选状态由 flat `filterIds`升级为类型化 `filterState` override，支持文本与排序升降序。
- source筛选面板按 schema类型渲染；恢复默认只清除用户 override，不覆盖插件自己的默认 Filter状态。默认 section仍由当前排序第一项决定。
- 新增 ADR 0152、dev.169根因审计与可执行 Kotlin Filter codec gate；版本提升到 `0.31.0+169`。

## 0.31.0-dev.168：收口 Source Filter Capability 与默认 Section 所有权

- 修复 dev.167“筛选入口依赖已加载 filter list 非空”的状态耦合：`FilterableBrowsableComicSource` 显式声明 `supportsSearchFilters`，Mihon runtime声明能力，Venera不伪装；筛选 schema临时为空或加载失败时分类栏入口仍保留。
- 筛选面板在当前 schema为空时显示明确空状态，不再通过隐藏入口表达“无能力”；opaque `selectedFilterIds`和原 browse/search request contract保持不变。
- 删除 source browser 用 `peekLatestBrowseProjection()` 反向恢复 section/query/filter UI状态的行为；cache只提供精确请求投影，不拥有默认导航状态。
- 默认 section统一由当前 Presentation排序后的第一项决定；当前标准排序为“最新 → 热门”，以后若加入用户自定义排序，只需改变同一个排序 owner，默认焦点自然随第一项变化。
- 新增 ADR 0151、dev.168根因审计与 owner gate；版本提升到 `0.31.0+168`。

## 0.31.0-dev.167：解耦 Source Browse 封面 Presentation 与筛选入口

- 根据 `zic-debug-trace-2026-08-08T09-45-09.jsonl` 审计 source browse/details交错刷新：删除把全局 browse projection `_contentRevision` 传给每个 `_RemoteImage` 的错误耦合；目录分页/后台 refresh变化不再强制整页封面重建。
- source card 的 Sliver direct-child key改用 `sourceId + canonical comic identity`，mutable raw locator仅保留 source调用与交互定位；详情补全或 alias变化不再凭 raw ID销毁封面 State。
- 新增 source-card artwork trace：按 canonical cover owner记录 load/source-ready/first-frame/source-failure/decode-failure，后续不再依赖 Home cover trace推断漫画源页失败。
- Mihon/source filters从浮动搜索面板移到分类栏末尾，标准顺序为“最新 → 热门 → 筛选”；筛选仍通过 opaque `selectedFilterIds`进入原 browse/search contract，不建立伪分类或第二过滤状态。
- 新增 ADR 0150、dev.167根因审计与 owner gate；版本提升到 `0.31.0+167`。

## 0.31.0-dev.166：拆分 Durable Artwork 保留生命周期并收口失效边界

- 根因确认：`FileResourceCacheByteStore` 原设计每次写入都执行同一 96项/32 MiB LRU/TTL trim，source browse封面、书架/历史封面、preview/avatar全部共享一个持久淘汰平面；maintenance还可把该平面压到24 MiB。dev.165只修复了删除后 FileImage悬空，没有阻止长期封面本身被普通浏览压力删除。
- 在唯一 `ResourceCacheManager/FileResourceCacheByteStore` owner内引入 `transient/retained` persistence lifetime，身份仍是原 `ResourceCacheKey`。browse/preview保持有界；library/history/details cover单调晋升 retained，不参与运行期容量/TTL/maintenance淘汰，显式资源删除与用户清缓存仍有效。
- catalog刷新从 artwork失效解耦：详情/章节 refresh仅失效 metadata，不能再以整个 comic namespace删除 image bytes；整漫画删除使用独立 `invalidateAllComicResources`。
- 修复 dev.165 编译闭包：恢复纯 `ResourceCacheByteStoreUsage/TrimReport/Maintenance`维护类型与 storage实现，但不恢复被否决的 cache-file path借用 API。
- 新增 ADR 0149、dev.166根因审计与 owner gate；版本提升到 `0.31.0+166`。

## 0.31.0-dev.165：收口 Artwork 文件生命周期与 Home 更新语义

- 根据 `zic-debug-trace-2026-08-08T07-28-36.jsonl` 收口封面间歇性 decode 失败：response cache 不再把可被 LRU/失效删除的持久 `.bin` 路径借给 Flutter `FileImage`；cache-owned artwork跨边界一律物化为自持有 bytes，`FileEncodedResourceSource` 只允许外部稳定本地文件。
- 删除 `PersistedResourceFile` / `ResourceCacheByteStoreFileAccess` / `ResourceCacheFileByteStore` / `locate()` 文件借用接口；storage byte store仍拥有磁盘文件、manifest、TTL和 trim，presentation不再拥有其生命周期。
- Home“更新漫画”改为显式 source-confirmed update projection：只有已在书架且 `SavedComicRecord.sourceUpdateAt != null` 的漫画进入；章节目录已有基线后发生新增/删除/revision变化或发现新的同源 successor/version才推进该时间。阅读进度、普通 metadata刷新和仅浏览/阅读记录不会产生更新。
- 远程漫画在 Home primary 尚无偏好时默认 `inShelf=false`；本地导入仍默认在书架。未入书架期间发现的 source update在首次加入书架时清零，避免历史浏览状态变成“新更新”。
- 新增 ADR 0148、dev.165根因审计与 owner gate；版本提升到 `0.31.0+165`。

## 0.31.0-dev.164：收口 Home 投影、Artwork revision 与 Runtime generation 所有权

- `HomeLibrarySession` 成为已挂载 Home 的 chapter/SavedComic write-through projection owner；详情/来源 materialize/迁移不再直接写 durable store后等待后续 `_reloadLibrary()`。Reader final progress改为 route-local，仅页面 callback enqueue，返回后发布一次内存投影。
- `HomeLibrarySession.reload()` 增加 projection revision：enrichment期间发生 write-through时，旧 entries/SavedComic snapshot不得回写覆盖新的阅读历史；download snapshot跟随最终可见 entries。
- 修复 browse与详情/历史封面 cache namespace分裂：`comicArtworkCacheSchemaRevision` 统一归 `resource_cache`，external gateway自行添加基础 revision并只接受额外 `contentRevision`；Home/详情不再生成 `artwork-v2:artwork-v2`。
- 删除 dev.163 Dart `_activatePlatformRuntime` 对 service-loss的二次 activation调用；Binder client只允许初次 pending activation跨一个死亡/断开的 service generation，并用纯 Kotlin policy约束 Venera/Mihon activation、错误类型与次数。
- 更新 dev.156/dev.157/dev.163历史 owner gates并新增 dev.164 gate、ADR 0147与根因审计；版本提升到 `0.31.0+164`。

## 0.31.0-dev.163：修复 Venera 启动期 runtime 丢失与阅读历史封面 State 漂移

- `plugin_host_bridge` 将 `runtime-service-died/disconnected` 的一次性恢复覆盖到**初次 activation**：Android runtime service 已标记旧 binding 丢失后，重新绑定并重放同一 activation 一次；插件 payload/业务错误不进入该恢复路径。
- 首页“更新漫画/阅读历史”横向列表把稳定 `section + canonical comic identity` key 提升到 Sliver 的直接 child，并提供 reorder index callback；Reader 返回只改变历史排序，不再因为 child state-loss 偶然销毁/重建封面 Future/ImageProvider。
- Home artwork trace 新增 `homeCoverSourceFailed` 与 `homeCoverDecodeFailed`，并使用 section-aware presentation identity，下一份设备 trace 可区分 source/cache 阶段失败和 Flutter decoder失败；不恢复 timer/watchdog/evict/Future join。
- 新增 dev.163 owner gate 与 Venera activation tests；版本提升到 `0.31.0+163`。

## 0.31.0-dev.162：原子化正文资源绑定并删除 Catalog Artwork 旁路

- 修复 dev.161 调用方迁移遗漏：`demo_home_source_compat.dart` 不再调用已删除的 `ComicSourceResourceGateway.loadBytes`，正文完整字节路径改用明确的 `loadPageBytes`。
- `loadPageBytes` 与 Reader/下载流式路径共用 `pageResponseLoaderFor`；完整字节 fallback 不再直接调用 `source.loadResource()` 绕过 shared host transport/request-plan 所有权。
- `ChapterDownloadService` 删除 `ConfigurableChapterResourceLoader/Transport` 两个可独立更新的兼容 setter，仅保留原子 `ChapterResourceAccess`，避免 loader/streaming transport 半更新状态。
- 删除仅由测试保活的 `CachedBrowsableComicSource.loadImage/loadImageSource` 与 `loadCachedSourceImage*` facade；catalog 只缓存 browse/details/chapter metadata，external artwork 统一经 `ComicSourceResourceGateway/ResourceCacheManager`。
- 更新 Venera/source-resource/cache owner tests 与仓库静态门禁；新增 ADR 0146、dev.162 owner audit/gate。

## 0.31.0-dev.161：统一默认 User-Agent 并收紧网络/缓存所有权

- 网络设置新增可编辑 User-Agent，默认 Android Chrome 150；composition 以动态 provider 注入通用 HttpTransport、Reader fallback、章节下载、插件仓库控制面和 source host transport。source 显式 UA、Mihon browser-session UA优先，不被全局 fallback 覆盖。
- 修复 dev.160 Mihon 1.6 ABI shim 编译闭包：移除 ABI asset generator 未提供的 `kotlinx.coroutines` 依赖，`CatalogueSource.lang` 正确 override；details/chapters仍基于原始 `SManga`。
- external source host replay 只允许无状态的一次性媒体响应：禁止自动重定向；响应发生 redirect、`Set-Cookie`、非媒体 body或未知 client wrapper时立即切回 source-owned client，不把错误 client 状态留在 Dart HttpClient。
- `ComicSourceResourceGateway` 统一接收默认 UA provider；裸 transport API收口为 `loadPageBytes/pageResponseLoaderFor`，只允许 Reader/章节正文绕过 response cache。metadata/artwork继续必须经过 `ResourceCacheManager`。
- 新增 network/cache ownership gate：App presentation不得创建独立 HTTP client；低层 source transport只能由 gateway构造；生产直连 HTTP owner使用显式白名单。

## 0.31.0-dev.160：修正 Mihon 目录身份并解除 Venera 运行时重启

- 对照当前 Mihon `CatalogueSource`：1.6 compatibility shim 对原始 `SManga` 并行获取 details/chapters；legacy fallback 同样以原始 manga 调 `fetchChapterList`，不再把补全后的对象作为章节请求身份。
- Venera Web 登录与外部 source settings 只调用当前 runtime capability，不再为设置/登录创建 replacement session；通用 `restartSource` API 删除，只保留 Mihon browser handoff 专用 restart。
- 生产外部 runtime session 安全上限由测试默认 8 显式提升为 32，避免安装较多 Mihon/Venera 插件时后续 session 因进程配额静默激活失败。
- 共享媒体 transport 删除 `zic-venera/0.31.0` 默认 UA。宿主直连得到 2xx 但前缀不是编码图片时，在字节进入 Pipeline 前转入已有 source-owned runtime network compatibility path。GET/HEAD 仍零 body。
- Mihon comic-details/chapter metadata cache revision 提升，避免旧错误空目录/单目录 durable manifest 遮蔽修正后的 source contract。Cloudflare 本轮未修改。

## 0.31.0-dev.159：对齐 Mihon 宿主接口并事务替换插件 runtime

- 以用户上传的当前 Mihon 主仓为接口基准：1.6 章节详情统一从 `Source.getMangaUpdate(manga, existingChapters, true, true)` 获取，`CatalogueSource` 自身负责兼容 legacy `fetchMangaDetails/fetchChapterList`；ABI 1.4 明确缺失 combined 能力时才由 ZIC回退 legacy。页面列表同理以 `getPageList(SChapter)` 为主，只有能力缺失才调用 `fetchPageList`。
- 删除 dev.157 的 `SChapter.url` 宿主去重。`getPageList` 接收完整 `SChapter`，相同 URL 不能证明两个 source object语义相同；driver内部 chapter object cache改为 sourceId作用域，避免同一 APK多 source串对象。
- Mihon正文与封面 request plan保存 `HttpSource.imageRequest(page)`/source headers生成的准确 method、headers和小型 request body；GET/HEAD保持零 body。宿主直连 transport解析 plan时同步补当前 OkHttp CookieJar Cookie和 browser-session UA；source-owned interceptor/transform仍通过既有 runtime-transform能力处理，图片正文不改为完整 Base64 RPC。
- `ExternalPluginRuntimeRegistry.replace` 先激活并校验候选 runtime，再原子替换 source owner并关闭旧 session；WebView/settings restart和已激活插件更新不再先 deactivate。候选激活失败时旧插件继续可用。
- 详情刷新接受来源成功返回的空章节目录，不再由 UI自行构造“请打开 WebView验证”错误；只有 typed `sourceVerificationRequired` 才进入验证恢复。
- 新增 ADR 0143、dev.159 Mihon接口/资源/插件生命周期审计与门禁；ADR 0142 的 explicit-first和 URL去重规则标为已取代。

## 0.31.0-dev.158：闭合详情Artwork接口并清理重复解码路径

- 修复 dev.157 owner-cleanup 未一次迁完的编译闭包：`storage_bridge` 补齐 `Uint8List` 导入，本地详情补稳定 `presentationIdentity`，详情 artwork loader 显式携带 `resourceRole`，preview/avatar 调用方与 decoded-artwork 构造统一到新接口。
- `ComicDetailsCoverLoader` 更名为 `ComicDetailsArtworkLoader`，同一 loader 明确服务 cover/preview/avatar 并把 role传给唯一 gateway/cache owner；presentation不再持有第二套 encoded-source接口。
- 普通未裁剪 artwork直接复用 `StableArtworkImage`；仅需要 Venera裁剪或尺寸测量的 artwork保留显式 `ImageStreamListener`，加载阶段不再同时构建第二个 `Image` 监听同一 provider，减少详情预览密集构建时的重复 decode/layout。
- 审查 Reader/storage/downloads/pipeline 热路径：Reader progress仍只向 storage-owned isolate/WAL队列发送 checkpoint；未新增同步 UI文件I/O。旧 artifact/prewarmer/nullability错误在 dev.157 当前接口中已闭合，不恢复兼容 facade。
- 清理稳定文档中与 ADR 0142 冲突的 presentation retry/watchdog/raw-cover旧合同；新增 dev.158 compile/ownership/blocking audit与静态 gate。

## 0.31.0-dev.157：清理阅读进度热路径并统一章节与封面所有权

- 根据 dev.156 真机回归重新逆向调用图：Reader checkpoint改为 storage isolate 8 秒 idle / 30 秒最大延迟批量提交，route不等待 durable barrier；返回后 Home/详情只更新当前 progress投影，不再全量 reload library。
- Mihon章节固定为 explicit `get/fetchChapterList` 优先、combined TachiyomiX 1.6仅能力缺失回退；真实目录错误不跨接口掩盖。删除 synthetic/title猜测，完全相同非空 `SChapter.url`仅按 source locator折叠。
- 删除 Home/详情/漫画源 presentation 层的封面 timer/lifecycle/first-frame retry、ImageCache eviction与 App级 Future join；durable artwork和 presentation State统一使用 canonical comic identity，恢复/cache只由 gateway/resource_cache拥有。
- 新增 ADR 0142、dev.157 根因/owner审计与静态 ownership gate；历史 ADR保留证据但不再作为当前生产合同。

## 0.31.0-dev.156：移出 Reader 持久化热路径并统一 Mihon 章节与封面身份

- 根因审计确认 Reader 卡顿来自 UI isolate 上同步 sqlite3/章节 JSON 读取以及逐页 `HomeLibrarySession` 发布，而不是串行顺序本身；新增独立 SQLite progress isolate，Reader 只入队，路由返回后再等待 barrier 并一次性刷新历史。
- 对照当前 TachiyomiX/Mihon API 删除 Mihon 人工 `SChapter`、按“开始阅读”标题猜测去重和 SManga 章节反射；章节只接受 `SMangaUpdate.chapters` 或 `get/fetchChapterList` 的真实返回，失败保持失败、成功空目录保持空目录。
- 修复 artwork 所有权：`mihon:resource:` 等非本地 locator 全部进入 `ComicSourceResourceGateway`；raw Mihon SManga opaque comicId 仅作 runtime locator，durable artwork key 使用 source canonical identity，browse/details/history 共用同一 namespace。
- `loadArtworkBytes` 复用 `loadArtworkSource` 的 source-independent durable probe；迁移封面和 cache invalidation也使用同一 canonical artwork identity。
- 新增 ADR 0141、dev.156 根因审计与 ownership gate。

## 0.31.0-dev.155：绑定真实 WebView 会话并修复历史/插件持久化

- Cloudflare 验证 WebView 不再伪装成插件静态 User-Agent；Cookie、localStorage 与真实 WebView UA 作为同一浏览器 session snapshot 持久化，Mihon 首次及后续同站点请求逐请求采用该 UA。
- 修复已持久化来源漫画再次进入详情时的同 identity 嵌套路由锁：外层 source route 已持锁时直接打开本地详情，不再二次申请同一锁。
- 首页阅读历史的 HTTP(S) 封面无论插件是否已恢复，都先走统一 artwork durable-cache probe；不再把网络 URL 误交给本地文件 loader。
- 外部插件 `installed.json` 改为逐记录容错；单个损坏/过时记录不再清空全部插件，旧 sandbox payload 绝对路径可在当前 owned root 按 basename 恢复，旧记录缺 `entryClasses` 时按空列表兼容。
- 插件页显示 manifest restore 失败诊断；新增 ADR 0140、dev.155 审计与 Cloudflare UA/历史/插件持久化门禁。

## 0.31.0-dev.154：等待 Cloudflare 验证稳定完成后再返回

- 验证 WebView 不再在单次 `onPageFinished` 后立即判断完成；任何新导航都会使旧 probe失效。
- 浏览器内部宽探针覆盖 Turnstile、challenge form、running容器、`cf-chl-*`、Cloudflare challenge iframe和 `Just a moment…` 等中间态。
- 页面必须 `readyState=complete`、progress=100、同站点且连续 3 秒无 challenge证据，才 capture最终 Cookie/UA并自动返回。
- 网络层 `sourceVerificationRequired` 分类继续保持 dev.153 的严格边界，不因浏览器内部宽探针而扩大。
- 新增 ADR 0139、dev.154审计和稳定完成门禁。

## 0.31.0-dev.153：收紧 Cloudflare challenge 并修复验证浏览器状态机

- `sourceVerificationRequired` 的 HTML判定对齐 Mihon 实际 `CloudflareInterceptor`：403/503 还必须有 Cloudflare Server 与 `challenge-error-title`/`challenge-error-text`，仅 `challenge-platform`、`cf-chl-*`、`Just a moment` 或普通 Cloudflare 403不再触发 WebView；`cf-mitigated: challenge` 仍作为明确协议证据。
- 可见验证浏览器不再预删 `cf_clearance`；同站点、同 UA且仍在 TTL 内的旧 snapshot 在新页面成功 capture 前保留，空 Cookie capture不会覆盖已有非空 handoff。
- WebView 同站点页面已经没有实际 challenge DOM时即可完成 snapshot handoff；`cf_clearance` 是 Cookie之一而不是唯一“完成验证”标志。
- 手动或自动 WebView handoff都会记录 source/request URL验证尝试；失败后后续普通刷新不再自动重复打开 WebView，成功 browse后才清除 guard，手动验证入口始终保留。
- 修复两处 `ComicDetailsSourceWebViewOpener` named callback编译闭包；新增 dev.153合同并更新 Cloudflare Kotlin正反例。

## 0.31.0-dev.152：同步 Mihon 验证 Cookie 并阻止重复 Cloudflare 回退

- `sourceVerificationRequired` 结构化携带实际失败 URL、HTTP 状态与请求时 `cf_clearance` 是否存在；漫画源/详情恢复优先打开实际失败 URL。
- Cloudflare 验证浏览器先删除已失效 clearance，只有获得新的非空 `cf_clearance` 才返回成功；用户直接关闭或未获得 clearance 不再触发必然失败的自动重试。
- Mihon `AndroidCookieJar` 将浏览器 snapshot 同步导入进程内 cookie map，首个 OkHttp 重试不再依赖异步 `CookieManager.setCookie()` 完成；CookieManager 仅作为兼容镜像。
- 新 runtime 若已经携带 `cf_clearance` 仍收到严格 Cloudflare challenge，不再自动打开 WebView循环，只保留错误诊断与手动验证入口。
- 新增浏览器模式参数 owner test、首请求 Cookie handoff Kotlin 行为门禁、dev.152 静态合同与 ADR 0137。

## 0.31.0-dev.151：修复验证后旧 runtime source 重试

- 漫画源页新增稳定 source ID resolver；外部插件 runtime 重启后，browse/section/filter 请求使用当前 active adapter，不再调用关闭的旧 session。
- WebView 验证恢复改为先确认 replacement source 已发布，再在新 adapter 上重载来源 metadata并强制刷新；恢复重试继续禁止二次 WebView fallback。
- `didUpdateWidget` 识别 source ID不变但 adapter实例已替换的情况，取消旧请求代次并重新加载。
- 新增直接模拟旧 source验证失败、WebView替换同 ID新 source的 Flutter owner test和 dev.151门禁。

## 0.31.0-dev.150：修复 Mihon common runtime 的 Release 保留边界

- 为动态加载边界使用的 `SourceVerificationRequiredException` 增加 consumer R8 keep 规则，保留原始类名和成员。
- 保持 Mihon common runtime 对 typed verification exception 的完整性预检；不通过删除预检掩盖 Release APK 缺类。
- 新增 dev.150 门禁，要求所有 `requiredMihonCommonRuntimeClasses` 中的 `dev.zic.network.*` 类型都有显式 release keep 规则。
- 新增 Mihon host ABI 断言，确认验证异常仍是稳定 common runtime 边界。

## 0.31.0-dev.149：端到端诊断并恢复 Mihon 共享扩展发现

- Mihon 页面打开时自动读取默认仓库索引，以仓库 package name执行精确 `getPackageInfo` 探测，不再依赖用户先手动加载仓库。
- 设备发现合并 `getInstalledPackages`、`getInstalledApplications` 与精确包名探测；每个 APK 的候选、metadata、签名与 ABI失败保留为可见诊断，不再由 `getOrNull()` 静默丢弃。
- App manifest声明 `QUERY_ALL_PACKAGES`；页面显示枚举、候选、精确探测、命中和逐 APK失败阶段。
- 明确设备扫描只覆盖系统共享扩展 APK；Mihon 私有目录扩展无法跨 App读取，应直接从 ZIC 仓库安装。
- 修复 dev.148 扫描协议 Dart闭包：实例 `trim` 调用、package name集合与换行错误；仓库请求失败不再覆盖设备扫描错误。
- 新增 ADR 0134、dev.149 审计、structured scan owner test与端到端静态门禁。

## 0.31.0-dev.148：修复 Catalog URI 编译与 Mihon 插件识别

- `CachedBrowsableComicSource.resolveComicWebUri` 恢复与 `ComicWebUriSource` 一致的 `Uri?` 合同，不再从非空方法返回可空值。
- Mihon runtime 不再直接 import/预检内部 `AndroidBrowserCookieSession`；浏览器快照 revision 重置通过稳定 `AndroidCookieJar.resetBrowserSnapshotImports()` 边界执行。
- Mihon APK metadata 识别支持 `android:resource` 字符串引用，并兼容逗号、分号与换行分隔的多个 entry class。
- 已安装扩展候选先按 feature 或标准 package prefix 识别，再执行完整 metadata 校验，避免资源型 entry metadata 在候选阶段被提前过滤。
- 新增 dev.148 owner/static gate 与 Kotlin entry metadata helper smoke。

## 0.31.0-dev.147：修复阅读历史提交并恢复版本查看与验证分类

- 修复 Mihon runtime 对 `AndroidBrowserCookieSession` 的缺失 import，闭合 Android 编译。
- Reader 进度改为串行合并写入；正常返回前等待最终 checkpoint，详情页在 Reader 返回后立即重载阅读历史；inactive/paused/detached 继续强制 checkpoint。
- 删除 App 对 synthetic“开始阅读/正文”的扫描、过滤和持久清理；Mihon adapter 只去除与真实章节并存的独立“开始阅读”动作。
- 参考 VibeVenera 恢复“查看新/旧版本”和“迁移”双动作；多个版本先选择，查看使用临时 route identity，持久历史继续按 raw 版本 identity 分离；迁移复用原严格对比确认 UI。
- Cloudflare 兼容 interceptor 改为统一委托 typed detector；仅严格识别的 403/503 challenge 映射 `sourceVerificationRequired`，删除隐藏 WebView、30 秒等待和错误文本分类。
- 新增 ADR 0132、dev.147 审计、Reader/章节/版本/验证专项门禁；native identity 不变。

## 0.31.0-dev.146：统一来源身份并收口同源更新与验证会话

- Preview/Comment capability 调用全部使用局部 `Object` 与显式 `as` 收窄，不依赖 getter/异步闭包自动提升。
- 真实 Mihon 章节存在时，在远程详情、SavedComic 持久目录和 imported chapter 三层删除“开始阅读/正文”兼容章节。
- 浏览器验证返回后重启目标 source；Mihon runtime 清空进程内 snapshot-import revision，使实际请求按当前 host/UA 导入最新同站 Cookie。
- `ComicVersionRelationStore` 增加 predecessor→successor 查询；详情页显示单一“有新版本”提示，Reader 首次提醒，移除旧版/新版列表及 AppBar 迁移按钮。
- AppPreferences schema v5 持久化每个 source/predecessor/successor 的 Reader 提醒确认。
- Architecture 补充 raw locator、canonical comparison、version relation、presentation 与 migration identity 对照。
- 新增 ADR 0131、dev.146 审计与静态门禁。

## 0.31.0-dev.145：原子切换来源缓存并修复封面所有权与验证回退

- 漫画源切换时立即按目标 source 的精确请求缓存或最近缓存替换页面投影；请求失败不再继续显示旧插件结果。
- Mihon 强制刷新返回 `sourceVerificationRequired` 时自动进入一次 WebView 验证，验证返回后重试一次且禁止循环。
- 底部来源 chip 删除 JS/插件图标，仅以背景色区分生态。
- Home 封面 State key 固定到 section + comic identity；重复卡片共享 source Future/provider，失败 Future 立即退出 join。
- 首帧 watchdog 只重建同一 ImageStream，不再把离屏/未绘制误判为 encoded cache 失效；只有明确 decoder exhaustion 才强制刷新 bytes。
- 修复详情 Preview/Comment capability 的 Dart 类型提升编译闭包，新增 ADR 0130、owner tests 与 dev.145 门禁。

## 0.31.0-dev.144：封面首帧恢复、详情来源就绪与排版收口

- 对 encoded source 已就绪但 ImageStream 无帧无错误的封面增加 2.5 秒有界 watchdog；局部强制重读同一稳定 cover cache identity，不清空全局缓存。
- 远程详情先显示已保存目录，后台等待当前 active source；预览和评论每次调用重新解析当前 adapter。
- 预览完整行使用全部媒体宽度，标题保留内容边距；稀疏末行可放宽至 2.4 倍，展开高度上限为屏幕 90%。
- 详情页与漫画源页的刷新进度及成功/失败结果继续由同一个 `AppPullToRefresh` 拥有，并修正结果图标位置。
- 真实 Mihon 章节目录存在时，在目录、持久条目和最终 UI 投影三层剔除兼容伪章节。
- 简介使用卡片，评论正文清理 HTML 换行，“继续”区域增加上下间距。
- 新增 ADR 0129、dev.144 审计与静态门禁。

## 0.31.0-dev.143：稳定封面恢复、预览行与插件验证会话

- 删除失败封面因 loader closure identity 变化触发的重复请求；source/decoder 重试期间保持同一占位图，成功帧到达后才切换，避免多次闪烁。
- 详情预览按实际行执行“含横图最多 2 张、纯竖图最多 3 张”；只在相邻三张内做最小局部重排，按可用宽度反算等面积尺寸，并移除内层 Card 与水平 padding。
- 详情页与漫画源页共用同一顶部边缘下拉刷新交互。
- 可见浏览器 Cookie 快照按 revision 在每个 runtime 进程只导入一次，避免旧 Cloudflare Cookie 覆盖 runtime 新 Cookie。
- MethodChannel runtime 对 retryable lifecycle envelope 执行一次原地重新激活，包含 `runtime-closing`；已打开详情页按稳定 source ID 解析当前 active adapter，插件重启后不再调用关闭的旧 session。
- 新增 ADR 0128、dev.143 审计与静态门禁。

## 0.31.0-dev.142：铺满详情预览并恢复封面与来源搜索交互

- 详情预览行在最大/最小面积比不超过 1.2 的前提下受限放大，完整行优先贴近屏幕左右边缘。
- 首页、漫画源卡片和详情封面统一支持 source Future 重试、失败 provider 驱逐、ImageStream 重建与 App resume 恢复。
- 浮动搜索展开态优先消费返回和垂直滑动手势；Mihon `getFilterList()` 投影为搜索框上方过滤标签。
- 漫画源页新增边缘下拉强制刷新，保留现有内容并绕过 catalog 缓存后台取新数据。
- 新增 ADR 0127、dev.142 审计、owner tests 与静态门禁。

## 0.31.0-dev.141：来源自有分类、浮动搜索与缓存后台刷新

- 漫画源页不再按原生/Mihon/Venera 占用分类行；Mihon 使用 Popular/Latest，Venera 枚举 explore/category 入口，来源生态仅以 chip 色彩和图标区分。
- 页码移动到内容滚动尾部；搜索改为左下浮动展开，搜索历史持久化并可删除/清空。
- 漫画源列表先显示 catalog response cache，再后台刷新；稳定字段未变化时不更新列表。
- 阅读设置新增详情预览每行最大数量，默认 4、范围 1–8；等面积与 80% 屏幕高度约束保持。
- 新增 ADR 0126、dev.141 审计、owner tests 与静态门禁。

## 0.31.0-dev.140：漫画源分类分页与等面积详情预览

- 漫画源页按原生/Mihon/Venera 分类，改为每页 24 项的显式上一页/下一页；搜索、来源和分类切换回到第一页。
- Mihon 已安装与仓库插件按插件声明或 source metadata 的规范化语言分类，支持多语言和未知语言。
- 详情预览折叠/展开共用等目标面积布局，保持原始顺序，最大/最小显示面积比不超过 1.2；折叠高度取第一行，展开区域不超过屏幕高度 80%，按钮居中且仅显示箭头。
- 新增 ADR 0125、owner tests 与 dev.140 静态门禁；Reader Pipeline、native identity 和缓存所有权不变。

## 0.31.0-dev.139：当前代码文档重新对齐

- 按 production source 重写 Reader Pipeline、角色/水位、网络、缓存、texture 和 retention 文档。
- 明确 encoded +7/-3、decode role +2/-1 与 holder 7/5/3/2 是不同层级，并记录 transition 独立首帧。
- 记录 NetLane 唯一网络权威、16/64 KiB transport 合并、1 MiB/256 KiB prefix hint、单 blit 与 1 项/2 分钟资源会话 retention。
- 规范近端 ADR 状态，新增 ADR 0122 作为当前 Reader Pipeline 综合入口。
- 新增 current-code documentation consistency gate；产品运行代码和 native ABI 不变。
- 修复首页冷启动关键路径：先呈现 App 并后台预热 native media，Home 不再等待整本队列恢复或外部插件激活；primary 封面投影先让出首帧，来源延后 ready 后可重试失败封面。
- 新增 ADR 0123、首页冷启动审计及 Home/plugin/downloads owner tests；目标设备时序仍待复验。
- 进一步修复首页封面整体等待：前台封面 encoded bytes 到达即返回 memory source，durable response 写入后台排队；新增快慢封面渐进显示测试，保留 warm durable file 直读。
- 新增 ADR 0124；真实设备上的各封面首帧间隔仍待复验。
- 修复首页远程封面先解析插件再查缓存的问题：先查 source-independent raw stable key，
  命中不进入插件资源路径；删除 dev.135 为 app 更新保留的 URL-derived/canonical 旧 key
  兼容读取和 alias 回填。导航页面改为 lazy 构建，避免隐藏书架重复创建封面 loader。
- 修复同一漫画源的旧/新 raw `comicId` 在插件未激活时暂时显示两张书架卡片：来源确认过的
  canonical identity 写入 `SavedComicRecord`，冷启动按该比较 identity 先做只读归并，raw
  request/chapter identity 和已验证 artifact/version 迁移保持不变。
- 详情页移除顶部重复标题，恢复可用的“继续”药丸按钮，并将带时钟图标的阅读历史放到
  按钮同一行、章节总数行上方；新增同源版本入口和可显示当前插件/来源的迁移面板，允许同源
  不同原生 ID 的 URL 版本迁移。Venera 版本入口复用运行时网络/Cookie，按 `#gnd` 关系读取，
  不再把版本检查误走标题 browse。已确认的新版关系持久化后，同源迁移面板也会显示旧版。
  App-owned modal panel 的关闭操作统一改为左下角 X。

## 0.31.0-dev.138：移除 Current 流量门控并恢复目标页首帧并行

- 删除 dev.137 的 `DownloadFlowGate`、`beforeReadChunk`、`downloadFlowPressure` 和 LiveCoordinator holder-depth 网络资格逻辑；current 继续由 NetLane reserved slot、priority migration 与 preemption 保护。
- transition depth 为 0 时新增独立 `t>0` refill，目标页首帧不再等待 current 达到 depth 3；首帧后恢复既有 staged 水位。
- 保留首页 primary/enrichment 提前发布和 transport 小块合并；7/3、7/5/3/2、5/3/2、target coverage 0.15 与 fresh texture 不变。
- 新增 ADR 0121、切页独立性审计、Dart owner tests 与 dev.138 静态门禁；native identity 保持 dev.134。

## 0.31.0-dev.137：提前发布首页封面并保护 Current 远程流量

- 根据设备 Trace 确认封面缓存/解析不是 1.88 秒延迟主因；`HomeLibrarySession` 并行读取章节投影和 SavedComic 后立即发布可生成封面的 primary 数据，分类、偏好、阅读状态和缺失默认值补写继续 enrichment。
- `DownloadJob` 将远程约 1.4 KiB 小块物理合并：首批 16 KiB 尽快启动 decode，之后按 64 KiB 执行 artifact/native ingress；流失败前已收到字节继续形成可恢复 partial。
- `LiveCoordinator` 增加 current producer 水位驱动的同源 cooperative flow pressure：启动/waitingSource/depth≤1 时背景任务暂停拉取下一块，depth≥3 即恢复；不取消 demand、不缩小 7/3 或 5/3/2。
- 新增 `downloadFlowPressure` Trace、首页 primary/enrichment 指标、owner tests、ADR 0120 和 dev.137 门禁；native identity 保持 dev.134。
- Android debug/profile/release versionCode 更新为 137，package/versionName 保持统一。

## 0.31.0-dev.136：修复 Catalog 缓存权重并清理无调用兼容层

- 为 `CachedBrowsableComicSource` 补齐 search/comic/chapter metadata 的结构化 byte-weight 估算；权重由拥有领域结构的 catalog 计算，`ResourceCacheManager` 继续唯一拥有容量、TTL、LRU 与 in-flight join。
- 修复 `PromotedArtifactCacheHandoff` 使用无返回值 `Future.catchError` 的运行时类型错误；提交任务改为显式 typed async owner，并保证错误回调失败不会产生第二个失败 Future。
- 补齐冷 Reader 测试 backend 的 `invalidateArtifact` 当前接口；不恢复旧 Artifact/Prewarmer/Ingress 兼容 facade。
- 删除全仓无生产/测试 import 的 App `local_webp_folder.dart`、`local_image_folder.dart`，以及旧 WebP-folder typedef、model、screen、picker、key alias；单文件 WebP 与 ImageFolder 当前 API 保留。
- `WebpLoadToken` 旧别名迁移为直接使用 `MediaLoadToken`；新增 owner tests、ADR 0119、dev.136 编译/死代码门禁和审计。
- Android debug/profile/release 继续统一 `applicationId=dev.zic.zic`、`versionName=0.31.0`，`versionCode` 更新为 136；native identity 保持 dev.134。

## 0.31.0-dev.135：统一应用版本并稳定缓存身份与版本复用

- Android debug/profile/release 改为读取同一项目版本文件，统一 `applicationId=dev.zic.zic`、`versionName=0.31.0`、`versionCode=135`，并显式禁止 applicationId/versionName suffix；避免运行模式切换因版本身份漂移触发卸载/降级处理。
- 封面缓存 key 改为 `source + canonical comic + cover role`；封面 URL/token 只作为真实请求 locator。首页封面 Future identity 不再混入 URL，旧 URL key 仅做一次单向迁移读取。
- Venera comic/chapter opaque ID 新格式只保留稳定 raw locator/epId，不再编码 title、cover、description、chapter title 或 sequence；旧 payload 保持兼容。
- `ArtifactCacheManager` 增加有界 alias/rekey、链解析、循环拒绝和安全 invalidation；`VerifiedArtifactReusePlan` 只按 checksum、E-Hentai image key 或唯一内容 hash 复用不同精确 URL 的页面 artifact，并已接入用户确认的漫画源迁移流程，只为确实存在的旧 artifact 注册 alias。
- 审计确认统一缓存所有权为：`ResourceCacheCoordinator.responses` 管理目录/封面响应，composition-owned `ArtifactCacheManager` 管理 Reader artifact；不新增 UI 私有缓存或第二套 page cache。
- 自动识别两个 E-Hentai gallery/version 的可信作品关系仍待来源适配器接入；禁止使用标题、作者或相同页码猜测。
- 新增 ADR 0118、dev.135 缓存身份审计、Venera bootstrap/cover/artifact reuse tests 与 dev.135 门禁；native identity 保持 dev.134。

## 0.31.0-dev.134：移除解码核绑定并复用 Reader 资源会话

- 根据 `zic-debug-trace-2026-08-05T02-47-39.jsonl` 确认 5 次 Reader 进入创建并销毁 5 套 Pipeline；current 的 18.3 MiB 热字节虽已命中，仍重复灌入新 DownloadSession/native source，耗时约 701/704/710/2865 ms。
- `PipelineReaderSessionHost` 改用 factory `acquire/release`；同章同 source revision 的权威 DownloadSession、SourcePool、DecodeSession、artifact handoff 与 media runtime 最多保留 1 项、2 分钟，重入只重建 Reader binding 和 presentation output。
- retention key 使用 loader URI/revision，不使用每次 build 重建的 loader object identity；不同 revision、配置变化、TTL 到期或容量淘汰时完整 dispose。
- 删除无设备证据支持且目标设备全部失败的 Android performance-core affinity：移除 `sched_setaffinity`、`android_performance.rs`、`zic_prepare_decode_thread` 与 Dart FFI 调用；Trace 字段保留兼容并固定为 0。
- 保留 dev.133 默认 platform channel/单 blit lane，因为本次 Trace 的 platform present 最大值已较旧路径收敛；不恢复跨 Reader used texture。
- native identity 更新为 `zic-media-core-dev134-abi6-lib00121400`；新增 ADR 0117、资源会话 owner test、Trace retention 指标和 dev.134 门禁。

## 0.31.0-dev.133：迁移 VibeVenera 后台重入直接字节与单 Blit 路径

- 根据 `zic-debug-trace-2026-08-05T02-01-59.jsonl` 确认 dev.132 热缓存仅 4 项/96 MiB，会被 7/3 邻页淘汰；即使命中 current memory cache，18 MiB 正文仍按 1 MiB 分段回放约 971 ms。
- `ArtifactCacheManager` 默认改为 10 项/256 MiB；完整本地不可变 origin 作为进程内 durable immutable 保留，current memory hit 以单个 body 直接进入既有 DownloadSession/native ingress。
- Android texture bridge 对齐 VibeVenera：默认 platform MethodChannel、一个串行 blit lane、普通 `mainHandler.post` 后 `scheduleFrame`；移除 background task queue、双 lane 与 `postAtFrontOfQueue`。
- decode worker affinity 改用实际 TID，并与 Android 当前 cpuset 求交后设置高性能核心 mask；成功后 best-effort 请求 VibeVenera 同款线程优先级。
- Android native identity 更新为 `zic-media-core-dev133-abi6-lib00121300`；下载 7/3、解码水位 7/5/3/2、两个 worker、fresh used-texture 生命周期保持。
- 新增 owner tests、ADR 0116、dev.133 静态门禁；正式 ZIP 继续排除 `.zic-workspace.json`，patch 不触碰本地 `patch_dir`。

## 0.31.0-dev.132：迁移 VibeVenera Holder 播放与本地热字节路径

- 根据 `zic-debug-trace-2026-08-05T01-21-36.jsonl` 撤销 dev.126–dev.131 的 startup-buffer gate；播放只消费 holder 中已有帧，缺帧时保留当前 output 并等待 producer 唤醒，不再阻塞其他页面 decode refill。
- `UploadSession`、`UploadRegistry`、`LiveCoordinator` 与 `PipelineReaderSession` 删除 startup buffering 状态、current-only eligibility、`decode-startup-deferred` 和 upload-to-decode 特例；历史 Trace analyzer 指标保留用于比较旧日志。
- 参考 VibeVenera worker 批处理：NativeCursor 首帧请求 1 帧，current 后续请求最多 2 帧；额外 native frame 由 cursor 有界持有并在 rewind/dispose 时释放，worker 数量仍为 2。
- 完整读取的 `content://`、`file://` 与 asset 不可变页面正文写入 composition-owned `ArtifactCacheManager` 内存 LRU；新 Reader 直接命中同一 DownloadId 热字节，不再重复读取大 SAF 文件。
- 新增 downloads/sessions owner tests、ADR 0115 与 dev.132 静态门禁；7/3 下载窗口、7/5/3/2 staged 水位、fresh texture 生命周期、partial source-growth 和 native ABI 不变。

## 0.31.0-dev.131：保留被暂缓 Source Wake 并禁止中途再缓冲

- 修复 startup buffering gate 暂缓其他页面 decode 时错误消费其 source revision；被暂缓页面保持 pending wake，之后升为 current 可立即 decode。
- `UploadSession` 在同一 output 生命周期内保留已完成的 startup buffer 状态；临时 transition/previous 后返回 current 不再于播放中途重新缓冲。
- native active decode promotion 改为幂等；已经是 current 的 worker 不再重复报告 active promotion。
- Trace analyzer 新增 `decodeStartupDeferredCount` 与 `playbackRebufferCount`，可直接识别被启动缓冲暂缓的 source wake 和播放后的再次缓冲。
- 新增 owner tests 与 dev.131 静态门禁；下载窗口、7/5/3/2 水位、fresh texture、partial source-growth 和 native ABI 不变。

## 0.31.0-dev.130：Retained Output 删除后的编译闭包

- 修复 dev.129 删除 `_RetainedAndroidTextureOutputFrame` 定义后，Android output projector 仍保留该类型判断导致的 Dart 编译失败。
- 不恢复 retained output 空壳；projector 继续只接受权威 `_AndroidTextureOutputFrame`。
- 强化 dev.129 所有权门禁，并新增 dev.130 编译闭包门禁，禁止已删除类型在生产源码中以声明、类型判断或构造调用形式重新出现。
- 不修改 fresh texture 生命周期、性能核心 affinity、下载/解码/播放策略或 native ABI。
- 正式 ZIP 继续排除 `.zic-workspace.json`；patch 不触碰本地 `patch_dir`。

## 0.31.0-dev.129：Reader 后台重入 Fresh Texture 与性能核心 Decode

- 根据 `zic-debug-trace-2026-08-04T23-49-35.jsonl` 重新区分首帧与后续播放：长后台后首帧仍约 46–90 ms，但前数秒已复用 texture 的 bridge/schedule 与 native decode 均出现约 4 倍退化。
- 对照 VibeVenera 的实际生命周期，已承载页面 output 的 Android texture lease 不再跨 Reader session 回池；只允许从未呈现的预热 lease 复用，非 resumed 生命周期清理 idle prewarm。
- 移除 dev.125 跨 Reader retained platform output 恢复；partial source-growth 与 sealed failure 边界保持。
- 用最近 playback deadline 的一次性 timer 取代 4 ms `Timer.periodic`，仅在下一截止时间到达时唤醒。
- Android 两个进程常驻 native decode worker 启动时 best-effort 探测最高频核心并调用 `sched_setaffinity`；同构设备、探测失败或系统拒绝时保持默认调度。
- `frameDecoded` 增加 `workerPlacementStatus`；Trace analyzer 增加性能核心放置与 reused texture bridge/schedule 指标。
- Rust 导出符号与 native header 已变化，Android native build identity 更新为 `zic-media-core-dev129-abi6-lib00121200`。
- 正式 ZIP 继续排除 `.zic-workspace.json`；patch 不触碰本地 `patch_dir`。

## 0.31.0-dev.128：Native Decode 优先级迁移

- 修复已排队 native decode 的 execution class 固定在首次 PageRole：far/next 页面升为 current 时，queued nonCurrent 请求原位迁移到 current 队首。
- 迁移保留同一个 cursor、Future、source epoch、partial source 和 completer，不取消或重建 DecodeSession。
- 已经 active 的 native call 只更新 worker execution class，不强制中断；最多等待当前一次有界 native 调用完成。
- worker pool 首次启动期间先登记请求，两个 worker 全部 ready 后统一调度，避免 isolate 启动顺序让 nonCurrent 抢先。
- `LiveCoordinator` 在 demand role 升为 current 以及 current source wake 时触发迁移；新增 `decodePriorityPromoted` Trace 和 analyzer 指标。
- 修复前设备 Trace 中，page 9 source 提前约 3.7 秒完整 ready，但 current 生命周期结束仍无 frame 0；page 7 retained output 在 current 期间冻结，旧 decode 直到降为 previous 才完成。
- 正式 ZIP 继续排除 `.zic-workspace.json`；Patch 命令直接使用 `$(python3 tool/workspace_config.py patch_dir --absolute)`。

## 0.31.0-dev.127：启动缓冲 Refill 闭包

- 修复 dev.126 启动缓冲死锁：current 首档 `c>2` 补到 depth 3 后，可在同一 DecodeId 上继续 `c>4/c>6`，直至达到实际启动目标。
- UploadSnapshot 在首帧后进入 startup buffering 时定向刷新 current decode scheduling，覆盖 upload/decode 完成顺序竞态。
-普通非启动期仍禁止同一页面连续独占 lane，长期 7/5/3/2 和首帧立即显示保持。
- Trace analyzer 新增 completed wait、outstanding buffering 和等待时长统计；修复前 Trace 检出 1 个持续约 3.78 秒的未闭合 buffering。
-清理 `LiveCoordinator` 中重复的静态单帧条件。
- Patch 命令统一直接使用 `$(python3 tool/workspace_config.py patch_dir --absolute)`，不再引入聊天级 `PATCH_DIR` 变量。

## 0.31.0-dev.126：启动播放缓冲与 Deadline Lead

- 首帧继续立即呈现，但 current 长动画在约 250 ms、最多 7 帧的 successor 缓冲建立前不启动动画时钟。
- 启动缓冲期间只允许 current 参与 decode refill；next/next+1 demand 保留，缓冲完成后恢复原 7/5/3/2 水位竞争。
- 播放 deadline 按上一帧从 present 调用到实际可见调度的耗时提前，避免把 Surface/MethodChannel 成本逐帧叠加到 WebP duration。
- 活动动画 ticker 从 16 ms 调整为 4 ms；无 runnable playback 时不运行。
- 新增 `playbackBuffering` Trace、analyzer 指标、owner test 与 dev.126 门禁。

## 0.31.0-dev.125：后台恢复保留输出与 Partial Source Growth

- Android texture pool 按完整 DecodeId 保留最后 platform frame，新 Reader 可先 redraw 恢复 output，后台 authoritative decode 继续并替换。
- NativeCursor 将未封缄 ABI decode failure 归一为 NeedMoreData；LiveCoordinator 只等待 source revision，不进入定时 recovery。
- 新增 retained restore/source-growth Trace 指标和 owner tests。
- `.zic-workspace.json` 改为机器本地配置，加入 gitignore，正式 ZIP 与 patch 均排除；`ZIC_PATCH_DIR` 可覆盖。
- README、Architecture、Spec 未修改。

## 0.31.0-dev.124：大 WebP 首帧与 Patch 交付

- 低性能设备启动期，本地 current 首个 output 前独占 local bucket；首帧真实 present 后恢复稳定 local=2，不改变 7/3、远程/全局 5 或 active session。
- output prewarm 改用最终对齐 DecodeTarget，避免来源画布尺寸导致首个 texture lease 未命中和 surface 重配置。
- LiveCoordinator 可原位刷新 queued download scheduling；不重启 active DownloadSession。
- Trace analyzer 增加 mount-to-first-frame、启动 local active/limit、首个 texture reuse 与 surface reconfigure 指标。
- 新增 `.zic-workspace.json`、workspace config reader，并要求每轮交付完整 ZIP、SHA 与 `git apply --index` patch。
- 新增 owner/static tests、ADR 0108、审计与 dev.124 gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.123：Current 下载抢占与纵向页面预组合

- `NetLane` 增加 queued/active rank migration；同 key 晋升 current 不取消重建。
- lane/source bucket 满载时，current 使用唯一 handoff slot 并请求取消最低 rank active task；临时超额严格不超过 1。
- 被抢占且仍有 demand 的下载在清理后重新排队并复用既有 session/partial。
- 纵向 Reader 预组合稳定 page shell；geometry 缓存 extent/prefix 并使用二分定位。
- 轻量 host cache 在空闲帧由 2 屏渐进预热至 7 屏；未新增图片或 texture 缓存。
- 新增 owner tests、Trace handoff/priority migration 指标、ADR 0107 与 dev.123 gate。
- README、Architecture、Spec 未修改。

## 0.31.0-dev.122：活动传输保留与 Partial WebP 前缀循环

- 动画 staged c/n/m/p 水位调整为 7/5/3/2；权威静态页仍以单帧视为水位满足，不拆分混合章节的统一 refill 状态机。
- 未封缄 WebP 已连续解出至少 30 帧后，若下一帧需要更多数据且播放缓冲耗尽，则在当前可用前缀内循环；后台 source 继续增长，后续循环可自然扩展到更多帧。
- 页面退出 7/3 窗口时只取消尚未开始的 queued transfer；已经开始写入 partial 的 non-resumable transfer 继续完成，避免切页后反复从 rangeStart=0 重新下载。
- promoted、active、queued 或 retry-pending DownloadSession 不再随 observation revision 重复提交；远程三次尝试耗尽后使用跨 revision 的 session 级有界退避。
- 页面 runtime 尺寸只更新 ReaderView 局部 notifier；已有源尺寸时忽略小于 1% 的舍入差异，纵向 anchor 微调阈值提升到 2 logical px，减少低性能设备的 build/layout 与滚动修正抖动。
- Trace analyzer 增加 partial-prefix loop 与 download-recovery 统计；新增 owner tests、ADR 0106、dev.122 审计和专项门禁。README、Architecture、Spec 未修改。

## 0.31.0-dev.121：静态单帧水位与 Reader 局部更新

- 权威静态页在 holder 或已呈现 output 中拥有一帧时，直接视为当前 decode 水位已满足；即使旧 demand 暂时仍是 current 8 帧，也不会继续参与 c/n/m/p refill 竞争。
- 不拆分静态/动画状态机：混合章节继续使用同一 staged policy，动画页保持 8/6/4/3，静态页一帧即满足。
- Reader current/stable 变化不再通过两层 `AnimatedBuilder` 重建整个 Scaffold 与 ListView/PageView；已挂载页面由局部 shell 仅在 active、keep-alive 或旋转变化时更新。
- 纵向一次 build 复用同一个 geometry 快照，避免 item extent 计算期间反复创建几何对象并降低同帧尺寸不一致风险。
- 新增混合媒体水位 owner test、纵向局部 rebuild owner test 与 dev.121 门禁；README、Architecture、Spec 未修改。

## 0.31.0-dev.120：定向预加载 Source Wake

- 修复 source-ready 预加载页仍被全局 staged refill 重定向：未消费 source revision 现在为对应 DecodeId 选择定向 refill，不再依赖后续角色变化触发。
- `_runDecode` 在任务实际开始时重新比较可用/已消费 source revision，避免 queued task 使用提交时的过期 `sourceWake` 布尔值。
- 普通补水继续使用全局 c/n/m/p 仲裁；定向 source wake 仍使用同一 staged policy，只把 eligibility 限定到产生 source 事件的页面。
- `decodeRefill` Trace 增加 source wake 与 revision 字段，analyzer 增加 `decodeRefillSourceWakeCount`。
- 新增“current decode 被阻塞时，prefetch source-ready 仍必须在 current 释放前完成 frame 0”的 owner test 与 dev.120 门禁；README、Architecture、Spec 未修改。

## 0.31.0-dev.119：预加载 Source Wake 与静态输出驻留

- 修复 `sourceReady` 被更高优先级 staged refill 重定向后永久丢失；waitingSource 页面仅在没有未消费 source revision 时才阻塞，并从全局候选中跳过。
- 删除 dev.118 `PageRole.visible` 及强制可见页 demand/protection，恢复由 7/3 窗口在进入视口前完成预加载。
- 权威静态 output 失去 upload demand 后进入无需求驻留态，不再立即 `demand-detached`；实际超过 128 MiB output budget 时由 FrameBudget 以最低优先级回收。
- 纵向轻量 host 保留半径与前向七页预取对齐；静态预热继续按页面实际尺寸使用 96 MiB 选择预算。
- 新增 source-wake eligibility、静态 output 驻留/预算回收 owner tests、`staticFrameKept` Trace 与 dev.119 门禁；README、Architecture、Spec 未修改。

## 0.31.0-dev.118：本地资源直连与纵向全部可见输出

- 本地 `content/file/asset` 完整响应改为 immutable direct ingress，跳过 Reader 临时 artifact 写入；local bucket 从 5 调整为 2，remote/global 保持 5。
- 本地文件读取不再投影成下载进度；presentation fallback 按 validators/length 直接重读同一不可变来源。
- Reader observation 增加全部视口可见覆盖，Pipeline 新增 visible role；全部可见静态页获得一帧 demand，FrameBudget 保护其 output。
- 静态 96 MiB 预热选择改为按页面实际尺寸估算；可见页优先，剩余预算用于视口外邻页。
- 新增 owner tests、ADR 0102、dev.118 审计与静态门禁；README、Architecture、Spec 未修改。

## 0.31.0-dev.117：单帧 WebP Bootstrap

- 修复 `targetWatermark=1` demand 被 staged refill 永久跳过，新增按 priority 执行的 `one>0` 单帧阶段。
- DecodeSession 在首帧后即可上报完整 animation metadata，不再等待 cursor end。
- 本地 WebP 初始作为潜在动画候选，权威分类后动态页恢复 8/6/4/3，静态页保持一帧预算。
- 新增 sessions/local_media_ui owner tests 与 dev.117 静态门禁。
- README、Architecture、Spec 未修改。

## 0.31.0-dev.116：运行时 WebP 分类与编译闭包

- 修复 dev.115 cache invalidation 可选接口造成的 Dart 编译失败；`invalidateArtifact` 内聚为 `ArtifactCacheBackend` 必需原语。
- DecodeSession 在权威 cursor end 后上报静态/动画信息，Pipeline 用运行时分类覆盖错误的 WebP hint并强制重新规划。
- 连续两页确认静态且无动画证据时，未分类页可获得一帧 static-warm；真实动画证据会立即停止推断。
- 纵向 current±4 轻量 host 保活不再依赖 `animatedHint`，避免静态 WebP 邻页被误当动画而反复挂载。
- 新增 `mediaClassified` Trace、analyzer 统计、owner tests、ADR 0100 与 dev.116 gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.115：空 Artifact 自愈与纵向静态 Host 保活

- 修复 durable cache direct-ingress promoted session 被 handoff 读取空临时 artifact，并将 0 字节正文写回 L1/L2 的缓存污染。
- `ArtifactCacheManager` 与 Memory/Persistent backend 拒绝、失效并删除空条目；长度漂移或空 materialize 会逐层失效并自动回源。
- `DownloadJob` 拒绝声明为 0 字节或最终未产生正文的图片响应，禁止空 artifact 进入 promoted 状态。
- 纵向静态页面 current 前后 4 页使用 `AutomaticKeepAliveClientMixin` 保留轻量 host；decoded frame、texture 与 bytes 仍由 Pipeline/FrameBudget 管理。
- Trace analyzer 增加空 artifact 与空 handoff 回写统计；新增 ADR 0099、owner tests 和 dev.115 gate。README/Architecture/Spec 未修改。

## 0.31.0-dev.114：纵向可见页 Demand 与静态输出内存预算

- 纵向 Reader observation 改为按页面与视口的真实交叠投影 current/transition；相邻页一进入视口即建立 demand，不再等待视口中心跨过约 50%。
- 静态页面采用 96 MiB 推测输出预算选择 7/3 窗口内的邻近 decode/upload，每页只解码一帧；128 MiB FrameBudget 仍是实际 output 回收权威。
- 静态纵向 ListView host cache extent 从 2 屏提升到 4 屏，减少轻量页面宿主过早 dispose；纹理和帧仍由 Pipeline/FrameBudget 管理。
- 修复 `PipelineMediaRuntime` 到 `PipelineOutputPrewarmer` 的无继承接口类型错误，改为显式 capability narrowing。
- Trace analyzer 增加 static-warm、无首帧 host dispose 与 frame-budget 回收统计；新增 ADR 0098、owner tests 和 dev.114 gate。README/Architecture/Spec 未修改。

## 0.31.0-dev.113：Texture Pool 与持久 Artifact 直连

- durable persistent/memory cache response 通过权威 DownloadSession 直连 sealed ingress，不再写 Reader 临时 artifact；失败时 reset 回可重试状态。
- ArtifactCacheManager 保留 key+length durability，memory-only session artifact 不会冒充已持久化资源。
- Android texture lease pool 提升到 media runtime factory composition；按 PageAsset 尺寸预热并跨 Reader 重进复用。
- waitingSource 无 source revision 变化时不再被普通 force/ticker 重复提交。
- 新增 owner tests、dev.113 gate、Trace 的 cache-resident 与 texture reuse 统计；README/Architecture/Spec 未修改。

## 0.31.0-dev.112：全局页面下载排序与自适应 WebP 前缀

- 页面传输改为 composition 共享全局 5 槽，按页面唯一 rank 和 local/remote source bucket 调度。
- 跨页退出窗口会取消对应 active/queued task；factory clone 保持同一 lane identity。
- 删除 startup background priority floor，pressure 释放恢复为 current output 已呈现且 `c>4`。
- partial WebP 按 page/frame key 学习 local 1 MiB、remote 256 KiB 的最小 decode prefix；sealed failure 不增加 chunk。
- Trace 增加 ranked download 与 decode-prefix 诊断；README、Architecture、Spec 未修改。

## 0.31.0-dev.111：缓冲解码恢复与启动近邻压力

- startup foreground pressure 只放行 n/m/p 近邻 artifact，far 7/3 demand 保留但延后实际读取。
- pressure 释放提升到 current output 已呈现且 c 水位达到 8。
- DecodeSession failure 保留 FrameHolder；UploadSession 继续消费已解码 successor。
- current/transition 增加最多四次、revision-bound 的有界 decode recovery。
- Trace analyzer 增加 decode recovery attempt 与 buffered depth。
- README、Architecture、Spec 未修改。

## 0.31.0-dev.110：分阶段解码水位与 last output 保留

- 增加 `last`/`next2` 角色；last 不占 previous/next 槽，只冻结并保留既有 output。
- 引入 staged c/n/m/p refill；transition 作为逻辑 n，batch 可自然越过阈值。
- DecodeSession 每产出一帧即唤醒 upload，首帧呈现不等待整批 refill。
- 串行化同一页面的 presentation，先发布首 Surface，再追到最新 pending frame。
- current→last 取消 active upload 并冻结，last→current/transition 恢复；frame budget 保护 last output。
- Trace 增加 `decodeRefill` 与 `lastFrameKept`；更新 owner tests 与静态门禁。
- README/Architecture/Spec 未修改。

## 0.31.0-dev.109：Cache tier 内聚与 Android native build identity

- 将 encoded-byte L1、LRU、in-flight join、tier lookup 和 write-through 内聚进 `ArtifactCacheManager`；backend 只保留 open/store。
- 删除独立 byte-cache 文件、过渡 cache interfaces、backend readArtifact 旁路及对应旧门禁。
- 删除独立 `NativeBlitter.configure` JNI；Rust `blit` 内部按 geometry mismatch 配置，并在 lock failure 后只重试一次。
- 增加 source native build ID、JNI symbol gate 与 Gradle preBuild 验证，禁止旧 `.so` 静默进入 APK。
- telemetry 使用 `surfaceReconfigureCount`；旧 configure/retry 字段仅由 analyzer 兼容读取。
- README/Architecture/Spec 未修改。

## 0.31.0-dev.108：统一 Reader artifact cache 与 Android texture geometry

- 新增 composition `ArtifactCacheManager`，统一 Reader page artifact 的 memory→backend lookup、读取可见性/backend 持久存在性、精确长度、并发读取合并、LRU与写穿。
- Memory/Persistent chapter service 改为可替换 `ArtifactCacheBackend`，删除各 backend presence capability、独立 read pool 及 transport/handoff 的重复分派；persistent cache read 直接按 durable index/path 打开，不再 materialize DownloadSession。
- transport、handoff、presentation bytes loader 和快速重进共享同一个 manager；普通 response cache 保持独立。
- Reader dispose 改用 lane-level `cancelAll()` 清除 active/pending task，避免 registry snapshot 遗漏 queued key。
- Android native texture 在首次、resize、Surface 重建或一次 lock failure 后配置 `ANativeWindow` geometry；lock status 4 只重试一次，禁止每帧配置。
- Trace 增加 configure/retry 与 blit-lock/fallback 汇总；新增 ADR 0092、dev.108 audit、owner tests 和 ownership gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.107：Reader 重进清理与 progressive artifact handoff

- persistent cache handoff 在读取临时 promoted artifact 前按 identity 与长度探测持久副本；命中时跳过重复 materialize/store。
- current/transition encoded bytes 从单个 whole-body chunk 改为受 foreground pressure 和 lease-through-stream 保护的 1 MiB progressive startup segments。
- Reader dispose 先 detach handoff listener，并记录 coordinator、handoff、media、downloads、workspace 分阶段耗时。
- 修复 nullable `ArtifactCacheReadScheduler` Trace projection 的编译错误。
- 新增 ADR 0091、dev.107 audit、owner tests、Trace analyzer 扩展与静态 ownership gate；README/Architecture/Spec 未修改。

## 0.31.0-dev.106：启动前景背压与整块 artifact ingress

- current/transition 的 promoted encoded bytes 改为单个 immutable body 注入 Reader DownloadSession，避免 1 MiB Dart stream 循环重复唤醒。
- 前景 artifact scheduler lease 保持到 response body 被真正消费，不再在整文件 materialize 后提前释放。
- Reader 在首次 demand 提交前建立 composition 级 foreground pressure；首帧已呈现且 successor 水位达到 2（或确认静态/结束）后释放。
- background 仍保留 1 MiB chunk quantum；下载 7/3、预解码 2/1、lane 5/3/2 未改变。
- Trace 新增 delivery mode 与 foreground pressure hold 统计；新增 ADR 0090、dev.106 audit、owner tests 和静态门禁。

## 0.31.0-dev.105：直接 promoted artifact 读取与 encoded-byte 热缓存

- persistent cache 命中不再调用 `DownloadSession.restore()` 执行 metadata/prefix sniff、SQLite cache sync 和状态通知；只恢复 artifact 元数据并直接读取 promoted file。
- 大于 1 MiB 的 promoted file 参考 VibeVenera，在 isolate 中执行整文件同步读取；current/transition 使用快速路径，background 继续 1 MiB chunk quantum。
- 新增 composition-shared encoded-byte LRU：默认 4 项/96 MiB、并发读取合并、快速 Reader 重进复用；不拥有 demand/decode/upload 状态。
- 快速读取失败回退同一 artifact stream，不错误转向 origin；Trace 增加 read mode、memory hit/join、materialize 和 hot-cache 容量。
- 新增 ADR 0089、dev.105 audit、owner tests 与静态 ownership gate；稳定 README/Architecture/Spec 未修改。

## 0.31.0-dev.104：分块 Artifact 调度与 retained cursor 连续性

- persistent artifact scheduler 从整条 stream lease 改为 chunk quantum；foreground 连续读取，foreground 压力期 background 同时最多占一个槽。
- background 每个 chunk 重新读取权威 demand priority，晋升 current/transition 不取消、不重开同一 artifact stream。
- `sourceRead` 增加 scheduler acquire 次数、最大等待和 foreground acquire 数，便于验证启动拥堵。
- `DecodeSession.detach()` 在保留 frame 时继续原 cursor，修复角色回切后重复上传 frame 0、需要切走再切回才播放。
- 新增 owner-package 回归、ADR 0088、dev.104 三清单与 ownership gate；7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.103：Reader 重进与 platform presentation 确认修复

- `SystemClock` 改为进程级 monotonic epoch，增加 Reader session create/dispose 生命周期 Trace，修复跨 session 导出时间轴不可比。
- Android texture MethodChannel 改用 background task queue；两个 output-stable blit lane 取代单一全局 lane，`scheduleFrame` 使用 main queue 前部执行。
- playback timer 对 platform acknowledgement 最多抵扣一个名义帧周期，避免 MethodChannel 回包延迟逐帧拉长动画。
- decode/upload role 晋升间隔改记为 predecode lead，不再误报 upload backpressure；旧独立时钟 Trace 的 source concurrency 仅按 session 报告。
- 修正 `platformOther` 重叠计算，不再从 platform upload 重复扣除外部 blit-lane queue。
- 新增 ADR 0087、dev.103 三清单、Kotlin background task queue stub 和 ownership gate；既定 7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.102：异步 texture schedule 与共享 artifact 读取调度

- 修复三项 Source Browser quarantine 向 `testWidgets(skip:)` 传入字符串导致的测试编译错误，改为布尔 skip、稳定 ID 注释和登记门禁。
- 修复 promoted artifact cold-open、Reader session dispose 与 native runtime prewarm 的弱类型 Future 错误链。
- Android texture 移除 blit lane 的 main-thread latch；retain/blit/replace 完成后异步投递 schedule，并在同一 platform-thread runnable 中回复。
- 新增 composition-shared persistent artifact read scheduler：总槽 5、background 最多 4、current/transition 保留槽；pending priority 动态跟随 Pipeline plan，晋升不取消流。
- `sourceRead` 增加 scheduler wait 与取得槽位时 priority，Trace analyzer 增加跨 Reader 最大读取并发。
- 新增 scheduler 单元测试、ADR 0086、dev.102 三清单和 ownership gate；既定 7/3、2/1、current/transition、5/3/2 不变。

## 0.31.0-dev.101：恢复文档职责并拆分 Android schedule timing

- 重写 README、Architecture、Spec、Implementation Plan、Implementation Status 和 Handoff，删除稳定文档中的逐轮 dev 堆叠、Trace 数字和验证结果。
- 新增 `DOCUMENTATION_POLICY.md` 与 repository gate，禁止版本历史、单轮推断和完成记录重新污染稳定文档。
- quarantine 从版本绑定的 `dev.100` marker 迁移为稳定 `Q-001` 至 `Q-003` ID；删除版本耦合的 dev.100 聚合门禁。
- 历史 feature gate 不再绑定当前 App build 或要求当前 Handoff 引用历史 audit。
- Android texture 将旧 `platformScheduleMicros` 拆为 platform-thread queue 和实际 `scheduleFrame()` call；旧 Trace 由 analyzer 标记为 legacy combined timing。
- 分析新设备 Trace：前帧主导仍集中在旧 combined platform schedule、native decode 和 channel dispatch；1 MiB promoted artifact stream 仍存在 1–3 秒尾部，保持为未关闭问题。

## 0.31.0-dev.100：测试隔离治理与 Android texture schedule/reply 修复

- 修复 `library_ui_test.dart` 未限定 key、`misc_settings_test.dart` 缺 scheduler import 的测试编译闭包。
- 删除重复/过时测试：App adaptive classifier、`RasterPlan.isRenderUpscaled`、以 filter quality 证明 codec resize 的断言。
- 修正 Reader download callback 条件、remote metadata persistence 和 refresh in-flight 测试。
- 三个 Whole-App Source Browser 时序测试登记为 dev.100 quarantine；匿名 skip 由静态门禁拒绝。
- Android present 等待 platform thread 实际执行 `scheduleFrame` 后，从 blit lane 直接 reply，避免第二次 main-thread result runnable。
- 启动时预热 1×1 Android texture lease；lease 立即释放。
- timing 拆出 `decodedLeadMicros` 与 `uploadBackpressureMicros`，analyzer 对 dev.99 旧 trace 按前帧 deadline 归一化 dominant stage。

## 0.31.0-dev.99：前帧端到端耗时与本地 artifact 1 MiB ingress

- 新增不合并的 `framePipelineTiming`：覆盖 worker ready/queue、isolate、native decode/metadata、decode/upload lane、source wait、output prepare、Android texture 原子子阶段、`platformOther` 和 fallback。
- 每次 output 激活仅记录前 12 个不同 frame 的首次 presentation；后续只记录 >=250 ms 端到端、>=100 ms present/单阶段、deadline miss 或错误。
- 增加 `tool/analyze_frame_pipeline_trace.py`，直接汇总 dominant stage、p50/p95/max、逐帧启动样本、sourceRead 与 taskFailed lane 时序；总 platform upload 不再与子阶段重复竞争 dominant。
- promoted artifact 本地流式读取由 256 KiB 修复为 1 MiB；普通网络 chunk 不变。
- 修复 refresh in-flight 发布竞态、章节打开未持久化已读、tiny WebP renderer filter 投影，以及错误报告中多个过时/脆弱测试假设；删除仅被旧测试引用的 `comicDetailsRetryKey`。
- 新增 ADR 0083、dev.99 三清单和 ownership gate。

## 0.31.0-dev.98：锁定 libwebp 离线归档与精确补丁准备链

- 从文件库取得并保留 `libwebp-1.6.0.zip`，锁定归档 SHA-256 与干净 `vp8_dec.c` SHA-256；默认构建不再依赖网络。
- `fetch_webp.sh` 将归档解压到 tool-owned immutable upstream cache；发现缓存漂移时自动从锁定归档重建。显式 `ZIC_WEBP_SOURCE` 必须匹配干净源哈希，避免旧补丁树进入 prepared 阶段。
- VP8 TLS patch 由文件库真实源码重新生成；`prepare_webp.sh` 统一 LF，先用 `patch --dry-run --fuzz=0` 验证全部 hunk，再实际应用并运行结构 verifier，杜绝 partial patch 被 token grep 误判为成功。
- 删除无生产调用且已证明脆弱的 `apply_libwebp_vp8_tls_patch.py`；host/Android source build 在归档可用时不再强制依赖 git。
- 新增 ADR 0082、dev.98 三清单、真实归档准备/缓存修复/修改源拒绝回归，并实际完成 host libwebp 静态构建与 Animated WebP smoke。

## 0.31.0-dev.97：Reader 50% 无缝播放交接与诊断 Trace 压缩

- `ReaderView.onPageChanged` 不再发出整数 targetless observation；stable page 改变时保留真实 fractional position，outgoing page 继续是 transition，避免 `demand-detached` 退休有效 texture。
- `ViewportResolver` 默认 50% 交接；新 stable/current 在 midpoint 接管播放，旧 transition 暂停，无 40%–60% 双冻结区。
- Pipeline runtime 在异步 UploadSession snapshot 后重投影既有 viewport，修复新页偶发不启动、回切才播放。
- Debug Trace 对高频 frame/decode/upload/scroll 事件作固定首事件窗口摘要，保留 count、首尾、min/max；错误与权威生命周期不合并。超长本地 identity 输出稳定 hash+长度。
- 修复 `ArtifactCacheStreamStore`、`FrameDecodeTiming`、`ExpectedLengthEncodedSource` 三处 Dart interface promotion 编译闭包。
- libwebp prepared tree 当时改用函数锚点 transformer；该机制已由 dev.98 的锁定归档、源哈希与精确 patch dry-run 取代。
- 新增 ADR 0081、dev.97 三清单、midpoint/Trace/CRLF patch 回归与静态门禁。

## 0.31.0-dev.96：常驻双 isolate 与单线程本地 WebP 播放

- 两个 Dart native decode isolate 由 App composition 在 `runApp` 前显式等待预热完成并进程期常驻；页面/cursor 不再关闭 worker pool。
- current 使用独立高优先级队列并保留一个 worker 槽，非 current 最多占用其余一个槽。
- transition→current 的 same-key decode/upload 改为等待 active 完成后 follow，避免丢弃有效帧和反复退休纹理。
- current watermark 从 1 提升为 2，保留两个 successor；既定 7/3、2/1、current/transition 和 5/3/2 不变。
- libwebp 锁定 1.6.0；新增自动 prepared-tree 补丁链，复用 VP8 TLS workspace；帧内线程固定为 0，明确拒绝额外 8 线程 worker interface。
- native WebP 改用预乘 `MODE_rgbA`，target canvas 使用预乘 source-over；Android 只逐行复制且不每帧设置 Surface geometry，Flutter fallback 删除二次预乘。
- source 增长且 metadata 未完成时主动刷新 demux；小于 8 px 的 contain target 不再放大；本地文件/DocumentFile 分块提升为 1 MiB。
- 新增 ADR 0080、dev.96 三清单审计、Dart/Rust 回归规格和 dev.96 静态门禁。

## 0.31.0-dev.95：直通缓存/native ingress 并改用目标画布 WebP

- 根据高性能设备 Trace 排除硬件瓶颈：native decode 中位约 70.7 ms、Android blit 中位低于 1 ms，但首帧仍约 1.7–2.3 秒，platform callback 最高约 1.59 秒。
- 对照 VibeVenera 通用媒体链，确认 ZIC 仍在缓存命中时整页物化 `Uint8List`、并发重复读取 promoted artifact、逐块同步写临时 artifact，并在 Dart/native 边界执行双重复制。
- 新增 `ArtifactCacheStreamStore`；持久缓存以范围流直接进入同一个 DownloadSession，流式 store 禁止 `PromotedArtifactReadPool` 再次整页 prime。
- `Artifact` 改用 `IOSink` 缓冲写，pause/seal/promote 时统一 flush；DownloadSession 只建立一份 owned chunk，并增加 native ingress 与 artifact write 聚合 timing。
- native media ABI 升至 6，增加 expected-capacity、reserve、commit；Dart 直接写入 native source 预留内存，兼容 `zic_source_append` 仅保留为旧调用 helper。
- WebP demux 仅在下一 descriptor 不可用且增长达到 512 KiB 或 source seal 时刷新；不因每个 source revision 重解析完整文件。
- ANMF rectangle 使用共享 start/end endpoint 映射，libwebp 直接缩放 fragment 到目标 rectangle，再在最终 target canvas blend/dispose；删除 source-size canvas 与每帧完整纯 Rust 缩放。
- 新增 promoted stream、artifact exact range、native reserve/commit header、相邻/奇数 rectangle 无缝映射测试，以及 ADR 0079、dev.95 审计和门禁。

## 0.31.0-dev.94：迁移常驻 WebP 解码 worker 与持久 demux

- 根据设备 Trace 定位：动画 `decodeMicros` 中位约 124.9 ms；Android native blit 约 5.6 ms，但 platform round trip 中位约 770 ms、最大约 1.69 s，主要等待发生在 Dart/MethodChannel 调度。
- 只读参考 VibeVenera 的通用 WebP pipeline，在 `bridge` 增加两个常驻 decode Isolate；帧解码不再同步阻塞 UI isolate。
- isolate 消息只传 native cursor/frame 地址、epoch 和小型状态，不复制像素或完整 WebP 字节。
- `media_core` 缓存 demux frame descriptors；只有 source 长度或 seal 状态变化才重新 demux，不再逐帧解析完整文件。
- demux descriptor 只保存 authoritative source 中的 offset/length，不再保留第二份完整压缩字节快照。
- dev.94 当时使用 advanced decoder config 帧内多线程；该历史设置已由 dev.96 的单线程 frame decode 取代。删除逐帧 full-canvas clone 的改动仍保留。
- `frameDecoded` Trace 增加 `nativeDecodeMicros` 与 `decodeDispatchMicros`，区分 native codec 与 isolate/queue 往返。
- 新增 demux reuse/rewind Rust fixture、C threaded decode smoke、ADR 0078、dev.94 三清单审计和静态所有权门禁。

## 0.31.0-dev.93：预解码动画后继帧并修复媒体测试闭包

- 修复 `upload_session_test` 的 cursor fixture 未绑定 `LoopCursor`，导致完整静态元数据未进入 UploadSession。
- 当时更新 Reader viewport 测试：50/50 覆盖属于 overlap；该历史合同已由 dev.97 的 stable/current midpoint 接管语义取代。
- 更新 LiveCoordinator source revision 测试：source seal 是独立权威 revision，应被 drain 一次。
- 修复本地媒体 viewport 测试对 transformed child 尺寸和 fitWidth 第二层 FittedBox 的过时假设。
- 动画当前 output 不再计入未来 prepared depth；DecodeSession 可在当前帧显示期间保留一个 decoded successor。
- UploadSession 在 deadline 前不提前替换 output，deadline 到达后优先消费已缓冲 successor；没有 successor 时保留旧 output 等待。
- Android texture telemetry 增加 MethodChannel 总往返和扣除 native queue/upload 后的 bridge 等待。
- Android `content://` seekable descriptor 通过 `/proc/self/fd` 直接分块读取，避免每 256 KiB 一次 MethodChannel 往返；不可 seek provider 保留原流式 fallback。
- 新增 ADR 0077、dev.93 三清单审计和静态门禁。

## 0.31.0-dev.92：修复静态/有限动画播放输出生命周期

- 根据用户实际回切复现 Trace 纠正 dev.91 结论：6 次页面挂载仅 3 次首帧；3 个已呈现帧的时长均为 0，却仍产生 `playbackFrameDue`，之后在空缓冲上反复 `decoding -> ended`。
- `PlaybackTimer` 对零/负时长保持 idle；已确认的静态帧不进入动画推进。
- 动画帧到期不再先删除当前 output，而是保留旧帧并将 `preparedDepth` 投影为 0；successor 上传成功后原子替换。有限动画到 EOF 时保留最后一帧并记录 `playbackCompleted`。
- 修复错误报告中的 `Stream.toList(growable:)` 测试编译错误；修正 native texture viewport 测试的根节点 tight-constraint fixture，不改变产品几何。
- 新增静态零时长、有限动画最终帧、零时长 PlaybackTimer 回归、ADR 0076、dev.92 三清单审计和所有权门禁。既定 7/3、2/1、current/transition、5/3/2 与 256 KiB I/O 不变。

## 0.31.0-dev.91：修复页面回切无限加载并补齐本地媒体 Trace

- 根据设备 Trace 定位：upload 消费 decoded frame 后，页面离开 current/transition 会退休 output，但仍在前 2/后 1 decode window 的 DecodeSession 不 detach，空 holder 对应 cursor 停在 EOF；回页反复 `decoding -> ended` 并永久 `waitingFrame`。
- UploadSession 在 demand detach 与 frame-budget trim 两条 output 回收路径中统一通知 DecodeSession；仅 holder 为空时标记 cursor 重建。LiveCoordinator 只在 retained decode 实际重置后提交 follow-up，upload 遇到 missing frame 也会唤醒现有 decode demand。
- 动画正常 frame advance 不重启 cursor；不保留整章 texture、不新增 Reader/App bytes/ImageProvider cache，7/3、2/1、current/transition 与 5/3/2 保持不变。
- 新增 `sourceRead` 聚合 Trace，区分 persistent artifact、session artifact、本地 file、Android document、插件资源与远程来源，并记录 open、首块、总流时长、块数、块尺寸和最大块间停顿。
- `frameDecoded/frameUploaded/framePresented/playbackFrameDue/pageOutputReleased` 增加解码、上传、呈现、播放迟到和 output 生命周期字段；高频 chunk 只聚合，不逐块写事件。
- 新增静态图页面离开再返回回归、UploadSession 输出退休回归、缓存/来源读取 Trace、playback lateness 测试、ADR 0075、dev.91 三清单审计和所有权门禁。

## 0.31.0-dev.90：修复 Mihon runtime 编译闭包与漫画身份别名

- 将 `NetworkBrowserSnapshotStore` 移入 `network_bridge/android/src/runtime/kotlin`；该 source set 同时进入 network AAR 与 `generateMihonAbiAssets` 的隔离 Kotlin 编译，并加入 Mihon runtime 完整性检查和 release keep 规则。
- 根据设备 Trace 定位同一 Mihon source 下 439/440 长度的两个漫画 identity：一个持久 342 章，另一个反复返回 1 章，且均非 synthetic。根因为 `comicId` 编码了可变 SManga 标题、简介和 memo。
- 新增 source-owned `CanonicalComicIdentitySource`；Mihon/Venera adapter 只用规范化作品 URL 比较同源别名，原始 opaque identity 继续作为唯一请求 locator，禁止把 canonical key 传回插件。
- canonical alias 合并与最优目录选择归 `catalog`；首页、书架和更新投影只显示一个漫画，优先保留真实章节更完整的 locator。详情和下载状态通过注入的 identity matcher 接受同源别名。
- App composition 按 canonical alias 检查目录回归；曾有多个真实章节时，空目录、synthetic-only 或单章节结果均不得覆盖。Trace 增加 requested/effective ID 长度、alias 数量和脱敏 canonical identity hash。
- 删除仅被旧门禁和文档引用的 `resolveComicDetailsRoute` 兼容 facade，并把 source identity/catalog 回归逻辑拆入 `demo_home_catalog_identity.dart`。
- 新增 ADR 0074、dev.90 三清单审计、catalog/plugin-host 回归和 dev.90 所有权门禁；Reader/Pipeline 策略未改变。

## 0.31.0-dev.89：稳定来源 Cookie 会话与章节目录

- 可见 WebView 使用来源运行时声明的精确 User-Agent；Mihon `AndroidCookieJar` 与 Venera runtime 通过共享 `AndroidBrowserCookieSession` 导入同站点、同 User-Agent 的原子 Cookie 快照。
- 保持主进程浏览器与插件隔离进程独立 WebView data directory，避免 Android 多进程目录锁冲突和数据损坏；共享的是有界会话快照，不是 WebView 私有数据库。
- 修复详情初始化刷新和下拉刷新并发时“章节已更新但显示红叉”；成功/失败结果图标 2 秒后自动消失，插件设置改为与 WebView、迁移一致的 IconButton。
- Mihon synthetic revision 升至 3；runtime 记忆已观察到的真实目录，App 持久层拒绝用空目录或 synthetic-only 结果覆盖真实目录，并收紧 `UnsupportedOperationException` 的能力缺失判定。
- 新增来源浏览、验证恢复、浏览器会话、详情刷新和目录回归 Trace；Cookie 仅记录名称与数量，禁止输出值。
- 新增 ADR 0073、dev.89 三清单审计和所有权门禁；Reader/Pipeline 的 7/3、2/1、current/transition、5/3/2、256 KiB 传输及本地 artifact 所有权未改变。

## 0.31.0-dev.88：修复来源验证闭环并完善详情交互

- 修复 Dart 3.12 无关 capability interface 不提升、两个 `Stream.toList(growable:)` 测试错误和 `reader_runtime` 测试缺少 `ContentKind` 依赖的编译闭包。
- `network_bridge.openBrowser` 改为等待可见浏览器 Activity 关闭；插件隔离进程在任何 WebView/CookieManager 使用前设置独立 data-directory suffix，避免主进程 WebView 打开即退出。
- Cloudflare interceptor 取消不可交互的后台 WebView和 30 秒等待，challenge fail-fast 投影为 typed verification；Mihon host 默认调用窗口为 45 秒、Android IPC envelope 为 65 秒，普通 timeout 不伪装成验证错误。
- 来源页和详情页在用户返回后才失效缓存并自动重试；历史 synthetic 单章以 revision 2 失效，目录失败或 timeout 不再退化为单章节。
- 详情右上角固定为地球 WebView、迁移、插件来源设置；加入书架后的本地详情继续保留来源能力。下拉刷新使用持续的刷新/绿勾/红叉状态图标。
- 来源分类和标签支持点击进入当前来源搜索，长按进入多选并复制；当前未建立聚合搜索或第二套搜索缓存。刷新、来源 action 和标签选择按 Presentation 交互所有权拆入 `comic_details_interactions.dart`，避免继续增长超大详情文件。
- 新增 ADR 0072、dev.88 三清单审计和所有权门禁；Reader/Pipeline 的 7/3、2/1、current/transition、5/3/2 与 256 KiB 传输未改变。

## 0.31.0-dev.87：统一来源验证回退并优化本地大图恢复

- 修复 `PluginHostBridgePlugin.kt` 缺少 `android.os.Bundle` 导入的 Android 编译闭包。
- Mihon runtime 将 cause 链中的 Cloudflare challenge 统一投影为 `sourceVerificationRequired`；来源首页、分页、封面、详情和章节/下载操作均提供同一 WebView 恢复动作，普通网络/解码错误不会误触发验证。
- 新增 `ComicWebUriSource` 能力，Mihon/Venera opaque identity 只在 plugin adapter 中解析；详情页右上角改为访问作品网页，下拉刷新仍是唯一刷新入口。
- 来源分类、来源标签和书架分类分区显示并过滤重复作者；自适应模型升至 v5，补充 long strip/vertical comic/scroll comic/长条漫画等条漫证据，纠正被来源切片后误判 LTR 的作品。
- 根据设备 trace，promoted artifact 恢复改为优先验证原子 metadata 与文件长度并单次读取；缺失/失配仍完整重算 CRC。默认完整校验 API 与 Pipeline/DownloadSession 权威边界保持不变。
- 使用文件库中的 libwebp 1.6.0 源码完成 host 增量/循环 fixture 检查；新增 dev.87 owner gate、回归测试、ADR 0071 与审计。

## 0.31.0-dev.86：修复详情 WebView 编译闭包并拆分共享网络桥

- 补齐 `ComicDetailsSourceWebViewOpener = Future<void> Function()`，一次修复 `comic_details.dart` 与 `source_browser.dart` 的四处类型未定义编译错误。
- 新增 `network_bridge` workspace/Flutter package，统一拥有来源 WebView、Cookie/localStorage 快照和 Android 平台网络辅助能力；App composition 直接调用稳定 facade；插件控制器不再转发通用 WebView/Cookie 命令。
- 将 `MihonLoginActivity`、登录快照存储、Cloudflare interceptor、Android CookieJar 与 fallback DNS 从 `plugin_host_bridge` 迁出；删除旧 `openMihonLogin`/`readExternalLoginSnapshot` MethodChannel API 和实现。
- Mihon 1.4/1.6 `NetworkHelper` 继续保留兼容包名，但改为消费 `dev.zic.network` 共享实现。共享类加入 parent-first、运行时完整性校验与 consumer ProGuard keep 规则。
- `plugin_host_bridge` 只保留插件信任、APK/脚本隔离、ABI shim、请求路由和生命周期；通用浏览器/Cookie/Cloudflare 不再由插件桥拥有。
- 浏览器 Activity 的进程名改为 manifest placeholder，由 App composition 显式选择；登录 snapshot 改为原子文件交换，避免跨进程 SharedPreferences 缓存导致读不到最新 Cookie/localStorage。
- 新增 network owner Dart 测试、Kotlin 提取编译、dev.86 静态门禁和 ADR 0070；更新全仓 analyzer/test runner、依赖白名单和文档。
- 未新增 rhttp 依赖，未改变章节目录判定、256 KiB 数据块、GET/HEAD 零 body、Pipeline 7/3、2/1、current/transition 或 5/3/2 lane。

## 0.31.0-dev.85：修复 Cloudflare 章节目录并流式读取本地大图

- 应用 staged 覆盖后继续收口：Mihon 章节目录调用失败不再创建 synthetic “正文”章节；只有目录能力不存在且 gallery 正文预检非空时才允许兼容单章。
- 详情首屏目录失败显示权威错误、重试和 WebView 图标；dev.85 当时由 App composition 注入 `openMihonLogin`，该临时入口已在 dev.86 迁到 `network_bridge.openBrowser`；Presentation 不访问 Cookie、runtime 或 session。
- 旧 synthetic 章节只在权威真实目录恢复后由 composition 协调淘汰；opaque Mihon identity 解析保留在 `plugin_host` 协议适配层。
- Mihon runtime 增加共享 Android CookieManager 的 Cloudflare WebView interceptor，覆盖 403/503、`cloudflare`/`cloudflare-nginx` 与 30 秒 challenge 等待；GET/HEAD 零 body 契约不变。
- transport、artifact 与下载 fallback 默认块由 64 KiB 提升到 256 KiB；source progress/Trace 的 64 KiB 聚合语义保持不变。
- 普通本地文件使用 `RandomAccessFile` 直接分块；Android `content://` 使用 bridge v4 的 `openDocument/readDocumentChunk/closeDocument` 句柄、range/validator 和取消关闭，不再通过单个完整 `Uint8List` 作为 Reader 常规输入。
- 新增 owner package 测试、Mihon 章节/ABI 契约、dev.85 静态所有权门禁、ADR 0069 与三清单审计。

## 0.31.0-dev.84：修复 Mihon 静态转译、章节目录与详情元数据

- 修复 JMComic/18comic 静态 WebP：按扩展 source client 的自定义网络能力选择 runtime transform，普通 Mihon 图片仍使用宿主流式 transport；transform 版本进入 chapter source revision，淘汰旧未转译 artifact。
- `SMangaUpdate.chapters` 非空时成为权威目录，删除组合更新后的重复 chapter-list 请求。
- 翻译并持久化 Mihon source name、description 与 genres/tags；详情页隐藏数字 identity、统一下载整本图标、增加“继续”药丸和可展开单行 tags。
- 章节行先按 chapter token、再按同 source/comic 的唯一 source revision 复用已持久化 page list，不重新预取全部章节正文。
- 修正 DecodeTarget 错误放大测试，并将 completed artifact 进度回归迁移为纯 snapshot projection。
- 新增 ADR 0068 与 dev.84 所有权门禁。

## 0.31.0-dev.83：恢复稳定预下载、每漫画自适应与物理像素拼接
- 普通来源方向、manifest `animatedHint` 与 `.webp` 后缀不再预填自适应结果；动画分类只接受 metadata 或两份实际运行时动画能力。

- 修复 `LiveCoordinator` 漏导入 `DecodeSnapshot/DecodeState/UploadState` 的 kernel snapshot 编译闭包。
- 删除按 `venera-resource` scheme 选择预取 profile 的分支；所有 Reader 统一 current+前7+后3 下载、current+前2+后1 预解码、current/transition 上传和 5/3/2 lane。
- 迁移 VibeVenera 可移植的 per-comic adaptive model v4：metadata、封面排除、两份几何/实际动画证据、0.60/0.80 confidence 与持久化 fingerprint；普通来源方向不再冒充 adaptive 事实。
- 本地 `.webp` 后缀不再直接写入动画 hint；GIF 保留固有动画 hint，WebP 由 metadata/header/runtime 证明。
- 连续 Reader page extent 按 DPR 落到同一物理像素栅格；stitched texture 直接填充权威 page box，移除普通滚动时每页独立 FittedBox/ClipRect/RepaintBoundary 边缘。
- 删除生产无调用的 `ReaderPipelineProfile.standard/sourceStreaming` 兼容别名。
- 新增 policy plan、adaptive classifier、metadata 持久化、physical boundary 与 texture direct-fill 的确定性 owner 测试和 ADR 0067。

## 0.31.0-dev.82：修复动画源网格合成、帧消费推进与 Trace 风暴

- Animated WebP 不再独立缩放每个 ANMF 子矩形；blend/dispose 在源 canvas 上完成，再统一缩放完整帧，修复纵向页面内部水平条带错位。
- frame timer 消费当前输出后独立补充 decode watermark，动画不再等待下一次网络 chunk；下载完成后仍可继续逐帧播放。
- source 增长按 64 KiB、seal、failure 边界唤醒 decoder；无实际 holder/output 变化时不记录或提交 decode/upload 工作。
- `bytesCommitted` 在 `DownloadSession` 按 64 KiB 聚合并在终态刷新；raw Trace 默认上限从 20000 降为 10000，避免短时间内导出巨大文件。
- 修复 controlled transport 测试在暂停 `StreamIterator` 时等待 `StreamController.close()` 的关闭死锁；纵向几何 double 断言改用容差。
- 新增 ADR 0066、dev.82 三清单审计、source-grid 合成单测与动画帧消费回归。窗口、lane 与所有权边界不变。

## 0.31.0-dev.81：修复 Mihon 宿主流式传输、动画上传竞态与章节即时入场

- Mihon `resolveResource` 只返回最终 URL/headers/GET request plan；宿主 transport 直接流入 `DownloadSession`，source-owned 完整字节 RPC 仅在直连及刷新计划均失败后兼容回退。
- `DownloadSession` 持有每次网络 run 的 `networkStartLength`，未知总长度在 committed bytes 增长后立即显示 receiving，而不是直到 seal 前都显示连接中。
- `UploadSession` 串行化同一 `DecodeId` 的平台 upload，并在 queued/active 操作排空后才 release slot；被 supersede 的结果或 `Failure(texture)` 不再写入新 revision，修复快速翻页后动画停滞。
- 章节入口改为 route-first：先 push Reader loading shell，再在 route 内加载 chapter、检查 artifact 与组合 response loader。
- 普通图、完整 WebP 与 Pipeline texture 的 Presentation 对齐统一为居中，不建立 WebP 特例。
- 删除 downloads/App 封面测试中的真实 loopback socket、30 秒 timeout、Reader `pumpAndSettle`、lazy child 数量、魔法 offset 和静态门禁强制的 400ms 等待；改为 controlled Stream/Future、注入单调时钟与纯 `ReaderVerticalGeometry` owner 测试。
- 修复 `FlutterActivity` 上不可用的 `registerForActivityResult` 编译错误，Android Trace 导出继续使用系统文档创建 Intent。

## 0.31.0-dev.80：修复增量流式唤醒、统一等比栅格与 Android Trace 导出

- `IngressSnap` 增加单调 source revision；Decode lane 按 `DecodeId` 排空活跃任务期间到达的增长/seal revision，并去重同 key 的后续任务，避免首个 partial decode 后直到下载完成才再次尝试。
- 未知 Content-Length 的传输投影按 committed bytes 区分 connecting/receiving，不伪造百分比；接收态公开实际新增字节。
- 新增 `AlignedRasterSize` 作为普通图片、DecodeTarget 与 native WebP 共用的 contain + 原比例 + 8 像素物理栅格契约；Dart/Rust 使用相同整数比较和 fixture。
- `MediaAspectViewport` 成为唯一 Presentation fit 决策。尺寸未知时不再落入 `BoxFit.fill`；header/static 原图尺寸也不会被对齐后的 output buffer 尺寸覆盖。WebP prefix 读取按 committed length 排空，避免同步期间的新 chunk 被吞。
- Debug Trace Android 文件导出改由 App 注入的 SAF `CreateDocument` 能力完成，不再调用未实现的 `file_selector.getSavePath()`；复制独立限制为 64 KiB UTF-8 JSONL，并报告截断或平台错误。
- 新增 source revision drain、统一 raster、未知尺寸 fit、transfer phase、raw copy/export 与 dev.80 静态门禁；+7/-3、+2/-1、current/transition 和 5/3/2 不变。

## 0.31.0-dev.79：恢复插件、封面与 Reader 流式稳定性

- Venera JavaScript source operation 改为单 in-flight；Mihon 保留配置并发。删除 WebView 内 60 秒 raw `comic.loadInfo` promise/object cache，详情缓存只由 `resource_cache/catalog` 持有。
- App 不再只把 HTTP(S) 视为 source-owned 封面。`mihon:resource:`、当前 Venera locator 等 absolute scheme 均进入 `ComicSourceResourceGateway`；`ResourceCacheManager` 合并完整 encoded-image resolution，避免同 key 重复 durable lookup 和回源。
- DownloadSession 在 source ready、每个增量 chunk、seal 和 source failure 时通知同一 lifecycle listener；listener 晚接入 ready source 会立即收到当前 snapshot。Decode lane 因此可在 `needMoreData` 后继续，并能在最终 seal 时完成解析。
- `DecodeSession` 将 ingress/source 和 cursor 异常保存为权威 failure；LiveCoordinator 唤醒 Upload，页面 output 显示失败，不再永久停留 loading。空 holder 的 demand 重入继续按稳定 identity 重建 cursor。
- 连续阅读未知页面 extent 不再依赖 mutable currentIndex；异步尺寸更新只在 idle 时保持顶部可见页的像素偏移，用户拖动/惯性滚动不会被 anchor jump 竞争。
- 运行时/header 确认 Animated WebP 后，自适应布局以 `runtime-animation` 高置信度覆盖 source vertical hint；显式漫画级方向覆盖仍优先。
- 新增 Venera/Mihon 并发、custom locator 封面、encoded cache 合并、source growth/seal/failure、decode failure output、稳定纵向 extent 和动画方向回归及 dev.79 静态门禁。
- 未缩小 +7/-3 下载、+2/-1 预解码、current/transition 上传或 5/3/2 lane。

## 0.31.0-dev.78：修复 Reader 等比输出、页面重入与原始 Trace 导出

- 补齐 `RendererKind` 显式 domain 导入；`UploadRegistry` 不再越权读取 `PlaybackState`，改用 `UploadSession.playbackRunning`。
- native WebP 将 decode target 解释为最大边界，按源 canvas 等比缩小且不强制放大；上传和 Android texture 使用实际 frame 尺寸，消除纵向压缩/拉伸。
- WebP 页面移出 demand 且 holder 为空后，再次进入会重建 cursor 并恢复首帧；不通过永久保留纹理或每次 EOF rewind 制造无限循环。
- 删除详情页自动遍历所有章节正文的页数预检，未知页数保持待加载；目标 manifest 写入后不再同步全库 reload，已读持久化也从进入 Reader 的同步路径移除。
- Debug Trace 拆分 UI projection 与最多 20000 条的 raw export ring；复制/文件导出使用原始事件，导出 capability 可测试并显示平台保存失败。
- 新增 fitted decode/upload、detach replay、章节不预取正文、raw trace copy/export 与 dev.78 所有权门禁。+7/-3、+2/-1、current/transition、5/3/2 未改变。

## 0.31.0-dev.77：Pipeline 媒体运行时原子迁移

- 新增原子 `PipelineMediaRuntimeFactory`/`PipelineMediaRuntime`，一次绑定 source、cursor、uploader、opaque output projector 与 renderer；每个 Reader session 创建并按依赖顺序关闭一个 runtime。
- 新增独立 `pipeline_native` composition package。`pipeline_runtime` 不依赖 `bridge`/`texture_bridge`，App 通过 `NativePipelineMediaRuntimeFactory` 注入平台实现。
- `PipelineReaderSession` 正式接通生产 `DecodeRegistry`、`UploadRegistry`、FrameBudgeter 与 LiveCoordinator；保持 +7/-3 下载、+2/-1 预解码、current/transition 上传和 5/3/2 lane。
- 删除 `PipelinePageStream.source`/`EncodedSource` Presentation 泄漏；Reader 页面改为消费只读 `PipelinePageOutputStream` 和不暴露 `DecodeId`、textureId/native handle 的 `PipelinePageSurface`。
- Reader WebP 不再由 `NativeWebpPlayer` 创建 cursor/texture。App 的媒体 Pipeline 演示同步迁移到 `LocalImagePlayer + PipelinePageOutputStream`，未保留测试专用旧参数。
- 暂停/倍速命令进入 Pipeline session，UploadRegistry 原子保存并向新旧 UploadSession 投影同一配置；用户 pause 与 viewport freeze 独立，异步 present 完成后读取最新 speed，避免旧命令覆盖或误唤醒 transition 页。
- Android uploader 按 `DecodeId` 复用 texture；identity 退休后等待最后一个 output claim/frame owner 释放再销毁 lease，session close 排空已退休 texture，避免长章节累积或旧 surface 使用已释放 texture。
- output replacement/清空先切换 snapshot，并在下一 Flutter frame 释放旧 claim；`LocalImagePlayer` 也只在 opaque surface 真正进入 widget tree 后报告首帧，避免 use-after-release 与过早 ready telemetry。
- playback ticker 只在至少一个 UploadSession timer 处于 running 时运行；静态页和全部 viewport-frozen 输出不再维持无效 60Hz 轮询，present/resume 会重新唤醒。
- 新增 runtime close、upload claim/retirement、composition smoke 与 dev.77 静态边界门禁；使用用户提供的 libwebp 1.6.0 源码完成 host build、增量解码和 loop fixtures 验证。
- 非 WebP 完整 artifact 的现有 Flutter Presentation 路径未在本轮伪装为已迁移；后续统一必须单独设计，且不得恢复第二条 Reader WebP decode 链。

## 0.31.0-dev.76：Reader 页面加载所有权与立即退出审计

- 删除 `ReaderView` 的 viewport 固定居中加载 overlay、`_readyPageKeys` 和由首帧回调驱动的父级 setState；Reader 不再保存第二份页面 ready 权威状态。
- 删除 `LocalImagePlayer.showLoadingIndicator` 兼容开关。静态图、GIF、WebP 的 loading/ready/invalid 继续由实际页面媒体呈现，纵向连续布局只出现随图片区域移动的加载反馈。
- 首帧回调继续由 `_ReaderPageHost` 去重并记录 `firstFrameReady` telemetry，但不再控制全屏视觉状态。
- 审计设备 trace：Reader 立即退出时 7 个 demand 均 detach，未出现 exception、退出后继续接收字节或 session 泄漏证据；当前页 WebP 首帧仍需在有 Flutter/Android 环境复验。
- 全仓检查其他 `CircularProgressIndicator`：Reader 控制栏只保留下载按钮工作态和 Pipeline 进度投影；封面、详情、仓库与路由初始化圈均属于其局部操作/内容 owner，没有第二个 Reader 固定居中 overlay。
- 新增 owner-package Widget 回归、Reader 禁止全局加载圈回归、静态所有权门禁和 ADR 0060。未改变下载/解码/上传窗口、lane、GET/HEAD、插件或缓存策略。
- 耦合审查另记录基线既有债务：`PipelinePageStream.source` 仍向 `NativeWebpPlayer` 暴露 encoded source，Presentation 仍创建 native cursor/texture。仓库尚缺 production `FrameUploader` 与只读 output 投影，因此本轮不做会形成双链或破坏播放的半迁移；后续必须原子收回 `pipeline_runtime`。

## 0.31.0-dev.75：编译闭包、契约归属与后续迭代提示词

- 修复 `home_widgets.dart` 将 `Future<Uint8List>` 返回给 `EncodedResourceSource` loader 的类型错误，并删除只被测试使用的 `ComicDetailsScreen` 兼容包装；详情测试直接覆盖真实 `LocalComicDetailsScreen` owner。
- 将 `AssetBundleTransport` 测试从 App 移到 `pipeline_runtime`，删除 App/Reader 对该内部 transport 的无用转出文件。
- 显式导入 Reader preference extension 和 domain-owned `ComicManifest`；不通过扩大 package export 掩盖调用方漏导入。
- 删除 App WebP 测试中重复的 `readerPageDownloadId` 契约，canonical download identity 继续由 `downloads` package 自己测试。
- 修复 Pipeline 测试对非 const `Coverage` 的 const 调用。
- 新增 dev.75 编译与所有权迁移门禁，并将仓库门禁更新到测试实际所有者。
- 修复 CI/本地验证覆盖缺口：`pipeline_runtime`、`reader_runtime`、`local_media_ui` 现在进入 `flutter analyze` 与 `flutter test` 主循环；为此前没有 test 目录的 `local_media_ui` 增加 package composition 编译 smoke test；`check.sh` 不再违反 `AGENTS.md` 自动执行 `dart format`。
- 新增 `docs/AI_ITERATION_PROMPT.md`，集中记录 Architecture、耦合审查、被否决退化方案、测试和交付约束。
- 未改变 Pipeline 的 7/3 下载、2/1 预解码、current/transition 上传、5/3/2 lane 或现有网络/缓存行为。

## 0.31.0-dev.74：稳定纵向几何、封面文件缓存与可用 Debug Trace

- 修复 `local_media_ui.dart` 在声明之后放置 `part` 指令导致的 Dart 编译失败，并新增全仓 Dart library 指令顺序门禁。
- 修复运行时媒体尺寸使用 `width / height` 而 Reader 连续布局要求 `height / width` 的单位倒置；删除拼接页的负 1 像素平移，不再用重叠掩盖错误几何。
- 连续 Reader 改用带 `itemExtentBuilder` 的可定位列表，并在首次 attach 前按保存页设置初始 offset。恢复第 87 页不再先挂载 0 到目标页，尺寸变化继续使用视口锚点而不是回跳。
- 来源浏览和详情封面统一消费 `EncodedResourceSource`/`FileImage`，不再把持久缓存重新读成 `Uint8List`/`MemoryImage`；封面 identity 不再混入章节 revision，成功封面也不会因列表 reload token 重建请求。
- 封面缓存升级为 `artwork-v2`，旧的无效响应自动旁路；新响应在写入前验证常见图片容器，HTML/错误页不会污染七天持久缓存。
- Debug Trace 增加 JSONL 导出、关键词/会话/级别过滤和严重度强调色；连续高频 mount/dispose/observation/demand 仅在 UI 投影中合并，失败事件完整保留。
- Trace 同时摘要 Mihon manga/chapter/resource opaque token，避免 identity 占据整份日志。
- 新增纵向恢复不挂载长前缀、封面文件恢复、无效封面不缓存、trace burst 合并及诊断 UI 回归。

## 0.31.0-dev.73：Pipeline 构造闭包与 Presentation 依赖收口

- 修复 dev.72 拆分后遗漏的 Dart 编译闭包：`ArtifactCacheStore`、`ContentKind`、`ReaderPipelineProfile`、`readerPageDownloadId`、`IngressSnap.source`、`NativeSourceFactory` 与 `_reportPageDimensions` 均改为正确的所有者接口或显式依赖。
- `PipelineReaderSessionFactory` 现在必须接收 `SourceFactory`；`pipeline_runtime` 不再依赖 FFI `bridge`，Native source 由 `local_media_ui` 的平台组合常量注入。
- 新增 factory 的不可变派生接口，页面本地 loader、artifact cache 和测试 byte loader 在保留 source factory 的前提下组合，禁止 Presentation 自行创建下载或解码所有者。
- `local_media_ui` 不再引用 `ArtifactCacheStore` 或调用 `readerPageDownloadId`；页面下载 identity 直接读取只读 `PipelinePageStream.identity`。
- `PipelinePageStreamSnapshot` 使用 Pipeline 自有 `PipelinePageContentKind`，不向 Reader/媒体 UI 泄露 transport `ContentKind`；encoded source 从权威 session ingress 投影，不再读取不存在的 `IngressSnap.source`。
- 恢复并帧后合并页面尺寸回报，只更新连续布局的只读比例投影，不创建下载、解码或重排命令。
- 新增 `test_pipeline_runtime_compile_boundary.py`，覆盖 SourceFactory 注入、包依赖闭包、只读 identity/content projection 与尺寸回调边界。
- dev.70/72 的前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传、5/3/2 lane、共享 request-plan 与流式进度逻辑保持不变。

## 0.31.0-dev.72：Pipeline 运行时所有权与共享请求方案复用

- 新增独立 `pipeline_runtime` 包，集中持有 Reader 会话的 `DownloadRegistry`、`LiveCoordinator`、`SourcePool`、artifact workspace、network/decode/upload lane、进度 publisher 与生命周期。
- `ReaderRuntimeScreen` 不再创建、销毁或直接引用下载/解码/上传/session/storage/transport 所有者；它只提交 `ReaderObs`，消费 `PipelinePageStream`、页面字节投影和当前页进度投影。
- 当前页传输进度选择迁入 `PipelineReaderSession.accept(ReaderObs)`，删除 Reader 对 page transfer selection 的第二条控制路径。
- 本地图片/WebP presentation 不再接触 `DownloadSession` 或 `DownloadSnapshot`，仅观察 Pipeline 提供的只读 encoded-byte stream。
- 首页、来源浏览、详情页与迁移对比的远程封面统一通过 `ComicSourceResourceGateway` 和共享 source transport/cache；不再各自调用插件完整 `loadResource`。
- Venera HTTP artwork 优先解析 `comic.onThumbnailLoad`，仅无 thumbnail hook 时兼容回退 `onImageLoad`；章节 durable locator 继续使用 `onImageLoad`。同 locator request plan 在 JavaScript runtime 与宿主 transport 中并发合并并有界缓存。
- 保持 dev.70 的前 7/后 3 下载、前 2/后 1 预解码、current/transition 上传和 5/3/2 lane；没有通过削减预下载或并发处理上行流量。
- 新增 Pipeline ownership、封面共享 request-plan、Venera thumbnail resolver 和 Reader 无底层所有权静态/回归门禁。

## 0.31.0-dev.71：来源资源原子绑定与组合层解耦

- 修复 `demo_home_source_compat.dart` 通过 `ChapterDownloadService` 静态类型直接调用 `setChapterResourceLoader`/`setChapterResourceTransport` 的编译错误；无继承关系的能力接口全部显式绑定。
- 新增 `ChapterResourceAccess` 与 `ConfigurableChapterResourceAccess`，将 complete-byte fallback 与 streaming `ByteResponse` transport 作为一个不可分割的组合值一次性注入。持久下载内部只读取同一 `_resourceAccess` 快照，避免运行中的下载观察到半更新配置。
- 新增 `ComicSourceResourceGateway`：统一负责 sourceId 解析、旧 Venera runtime locator 拒绝、`ExternalPluginResourceTransportPool` 生命周期、Reader response loader 与章节下载绑定。`_DemoHomeState` 不再直接持有 transport pool 或调用下载服务的资源 setter。
- gateway 关闭时先解除其绑定的下载服务，再关闭 transport pool；外部注入且晚于 Home 存活的下载服务不会继续保留指向已关闭 gateway 的回调。
- 将章节页面读取、单章下载和整本下载动作收回 `_DemoHomeState` 的专用 extension，删除“把整个 State 传给全局 helper”访问私有下载/会话字段的隐式耦合。
- 保留旧 loader/transport capability 作为第三方与测试服务兼容面；生产 `PersistentChapterDownloadService` 使用原子 capability。新增原子流式优先、gateway 关闭解绑和 legacy locator 前置拒绝回归及静态门禁。

## 0.31.0-dev.70：VibeVenera 风格流式来源管线与稳定进度

- 以 dev.69 为唯一基线，对照用户上传的 VibeVenera `Streaming Image Pipeline Architecture`、共享下载流、稳定预取窗口和进度 publisher，撤销“Venera 只请求当前页”的退化。
- 新增 `ComicResourceRequest` 能力边界：插件只解析图片 URL、method、headers、body 与变换需求；普通图片正文由共享 host transport 直接流入既有 `DownloadSession -> Artifact -> Ingress`，不再等待完整 `Uint8List` 或经插件 RPC 搬运整图。
- Venera 稳定窗口恢复为前向 7 页、后向 3 页下载；前向 2 页、后向 1 页可预解码；只有当前/过渡页上传。network/decode/upload lane 分别为 5/3/2，JavaScript request-plan runtime 仍串行，避免全局 request context 串号。
- GET/HEAD 在 JS 和 Dart transport 两层强制无 body/实体 headers；同 locator 的并发 request-plan 解析共享进行中的 Future。来源 `onLoadFailed` 只生成替代 request plan，不再迫使普通图片回退到完整 RPC body。
- 章节持久下载优先使用 streaming `ByteResponse`，每个 chunk 更新 authoritative session；80ms 合并投影真实已收字节和页内进度。下载管理在首个 chunk 后退出“连接中”不定进度，完成页不再重现网络态。
- Reader 当前页进度独立为 `ReaderDownloadProgressPublisher`：立即同步页切换、只显示 queued/receiving，sealed/promoted/restore 均隐藏，避免已完成页面切换时进度条闪烁。
- 流响应支持 subscription cancel/discard；错误响应不再为重试完整读取正文。普通窗口 detach 仍保留已经 receiving 的连接，显式取消/关闭才终止，遵循 VibeVenera 的 detach-not-eviction 规则。
- Debug trace 对 Venera resource/comic/chapter 的 Base64 locator 使用 hash+长度摘要，identity 与嵌套 payload 均不再打印完整 token。
- Pipeline demand 去重与 viewport/playback 更新解耦：相同 role window 不重复提交下载/解码，但拖动覆盖率仍逐 observation 更新呈现；同 sourceId 的新 wrapper 也不会关闭旧 Reader 正在使用的活动 transport。
- 新增 GET 零上传、首 chunk 早于完整 body、显式 discard、runtime transform fallback、`onLoadFailed` 替代计划、章节 chunk 进度、完成 artifact 不闪烁、7/3 下载与 2/1 预解码分层回归。

## 0.31.0-dev.69：Venera 原生二进制、请求取消与稳定连续锚点

- 对 dev.65–68 做差异审计并记录未闭环项：durable locator 到 dev.68 已进入真实日志，但普通图片正文仍经 JavaScript/Base64 桥；原生连接在 demand 解除后继续到超时；尺寸更新会调用当前页同步；纵向测试仍直接读取未构建 lazy separator。
- 普通 Venera 图片使用 `http_binary` 原生快路：JavaScript 只接收一次性 token，图片字节由 Android 原生响应直接回到 runtime packet；仅当来源声明 `onResponse`/`modifyImage` 时保留兼容的 JS 字节路径。
- GET/HEAD 强制清空 body 与实体 headers，Venera 默认并发降为 1、Reader deferred window 降为仅当前页；Pipeline 对完全相同的 role window 不再增加 revision 或重复提交 demand。
- requestId 进入每个 Venera bridge HTTP 调用；cancel 会立即 disconnect `HttpURLConnection` 或 cancel fallback call，JS finally 显式释放 request-scoped 状态。页面关闭后不再让已解除 demand 的网络工作继续到超时。
- 每漫画纵向拼接改为继承/启用/停用三态。旧 `verticalStitch:false` 迁移为继承，避免仅设置方向时暗中关闭全局拼接。
- 连续 Reader 在尺寸或 viewport 改变时保存可视中心的页面内锚点，重排后恢复；拖动/滚动期间不执行恢复或当前页同步。拼接模式无 separator，并对后续页面做 1 logical-pixel 覆盖以封闭物理像素舍入接缝。
- 页面内部 loading spinner 在 Reader 中关闭，改为 viewport 级唯一加载指示；未知当前页至少占满 viewport，真实尺寸到达后无裁切重排。
- 修复 `reader_navigation_test.dart` 原第 309 行：先导航并等待第二页进入 lazy list，再通过已构建 element 读取 gap；新增媒体尺寸、视口锚点、偏好迁移、pipeline 去重与 Venera 原生二进制/取消门禁。

## 0.31.0-dev.68：Venera 入口预检、请求止损与无缝连续布局

- 修复远程详情以 `refreshRemote: false` 打开已存在章节时绕过旧 Venera locator 迁移的问题。只要章节含 `venera-resource://token`，Reader/单章下载/整本下载入口都强制刷新章节元数据；刷新后仍为旧 token 时在进入 pipeline 前失败。
- App source-resource composition 与 Venera runtime adapter 增加独立止损门：旧 token 在插件 runtime 调用前被拒绝，避免遗漏入口再次产生确定性失败请求。
- Venera deferred resource Reader profile 收窄为当前页加一张前向编码页，把单次 download demand 上限降为 2，并关闭 Reader 层自动网络重试；相同 URI 仍只共享进行中的读取，完成字节继续归既有 session/artifact 所有。
- 纵向拼接模式不再创建零高度 separator，而是使用完全相邻的 builder children；非拼接模式才创建 8px 间距。未知活动页至少占满一个 viewport，使加载指示保持在可视区域中心；拼接呈现使用 `fitWidth` 对齐页面宽度，真实尺寸到达后按完整图片比例重排，不裁切也不拉伸。
- 新增旧 locator UI 刷新、runtime 调用前拒绝、保守 demand window、无 separator 拼接和 viewport loading placeholder 回归及静态契约。

## 0.31.0-dev.67：Reader 控制所有权收口与组合解耦

- 修复 `demo_home_source_compat.dart` 对无继承关系能力接口的交叉类型提升编译错误；旧 Venera locator 刷新现在显式绑定 `RefreshableChapterComicSource`。
- 删除顶部 Reader 中与底部 Slider、手势和每漫画设置重复的页码、上一页/下一页、选页菜单与布局切换；顶部只保留返回、章节标题、可选只读页面副标题、传输进度和本漫画设置。
- 删除 `ReaderAppBarActionsBuilder`/`appBarActionsBuilder` 以及任意 Widget 标题注入，改为窄化的纯字符串 `pageSubtitleBuilder`；本地文件 Reader 不再直接持有 `ReaderController` 或调用 `requestPage`。
- 将 `ReaderSessionSettings`、自适应 profile 与分类函数从 `reader_runtime_screen.dart` 拆到独立模型文件；runtime screen 重新低于 1500 行，并增加结构门禁防止重复控制 API 回流。
- 纵向跳页在目标页面完成懒构建、进入目标视口并发布 observation 后才确认命令；测试按稳定语义 key 等待目标页，不再假设固定两次 pump 足够。
- 移除本地文件 Reader 已废弃的页码/前后翻页/选页公开 key 和兼容别名，更新 UI/Reader 契约回归。

## 0.31.0-dev.66：Venera 代际刷新、请求合并与实测连续布局

- 修复 dev.65 自描述 Venera locator 的作用域错误：资源恢复函数显式接收当前来源对象，不再引用仅存在于 operation 局部作用域的 `source`。
- 章节元数据缓存引入 durable-locator schema revision；打开、单章下载和整本下载遇到持久化的 `venera-resource://token` 时，先通过刷新能力绕过旧章节元数据并从来源刷新，避免不可恢复 token 被 Reader 反复重试。
- Venera runtime 按 locator 记忆已解析的 `onImageLoad` 配置并合并同一运行时的并发解析；Dart source adapter 只在请求进行期间合并相同资源读取。完成后的页面字节仍由 Reader/download artifact 所有者管理，不新增长期页面缓存。
- 纵向连续 Reader 不再用整屏高度猜测未知页面。静态图片从同一份已取得字节读取 PNG/JPEG/GIF/BMP/ICO 头，WebP 复用既有容器解析尺寸，再按真实比例重排；不创建第二条 `ImageStream`，不裁切漫画内容。
- Reader 方向切换、页码跳转和上一页/下一页命令会等待新滚动容器 attach 且具备 content dimensions 后再执行和确认，修复布局切换后顶部控制栏失效。
- 新增旧 Venera locator 刷新、章节缓存代际、并发资源合并、实测媒体几何、连续列表跳页及顶部控制栏跨布局回归。

## 0.31.0-dev.65：持久 Venera 资源、每漫画自适应与连续 Reader

- 修复 `MihonRuntimeDriver.kt` 使用 `Locale.US` 但未导入 `java.util.Locale` 的 Android 编译阻断。
- Venera 章节页面改用版本化、自描述且仅允许 deferred image identity 的 `venera-resource:` locator；运行时 token 表丢失后仍可重新执行来源 `onImageLoad`。旧 `venera-resource://token` 仅保留读取兼容。
- `DebugTraceLog` 的 enabled/record/clear 通知按帧合并，禁止在 Reader Widget build 中同步 dirty `AnimatedBuilder`。
- 新增全局自适应布局和纵向拼接设置，以及按 `sourceId + comicId` 持久化的每漫画方向、拼接和自适应覆盖。
- 自适应布局参考 VibeVenera 的“全局开关 + 每漫画覆盖 + 置信度门槛”，但只使用当前领域已有的来源方向、页面几何和动画提示；不创建模型或直接输出 pipeline demand。
- Reader 纵向模式改为按页面比例的连续 `ListView`；拼接只移除页间距，不合并页面/artifact identity。RTL slider 的 Directionality、端点标签与页面顺序保持一致。

## 0.31.0-dev.64：杂项页、分层设置与编译闭环

- 修复 ChapterDownloadService 能力接口绑定与 Map 下标测试编译错误。
- 新增第四页“杂项”，包含快捷设置、设置、关于与 Debug trace。
- 设置页按数据、网络、书架、阅读、下载、外观分层；数据备份和统一缓存维护可执行。
- 主题、书架默认值、Reader 默认模式/沉浸行为和整本下载策略持久化或复用现有持久队列。

## 0.31.0-dev.63：插件资源传输、媒体识别与章节元数据渐进收口

- 严格以用户上传的 `zic_v0.31.0-dev.62_source-management-tabs-mihon-chapter-preflight.zip` 为唯一代码基线；`mihon-main` 与 `vibevenera-master` 仅用于兼容行为对照，未修改、未并入产品源码。
- `ImportedChapterRecord` 只要求稳定 `pageId` 唯一，不再把可重复的资源 URI 当作页面主键。同一图片地址可在章节中出现多次，而下载、进度与 Reader identity 仍由不同 `pageId` 区分。
- `PersistentChapterDownloadService` 新增可注入的 source-resource loader，并在 `downloads` 内为 `mihon:`/`venera-resource:` 等来源私有 URI 选择 `LoaderTransport`。App composition 只绑定当前 source registry，不在详情页或按钮中复制下载分流。
- Reader transfer progress 改为按帧合并、在 build 结束后发布，避免 `ValueListenableBuilder` 构建期间被同步 `DownloadSession` snapshot 再次标脏。
- Venera 章节页根据原始资源名提供 WebP/GIF/PNG/JPEG/AVIF 提示，本地媒体名也补齐常见格式识别；提示只用于快速选择，实际字节嗅探和 codec 仍是最终裁决。
- Venera native HTTP 默认继承受限 WebView 浏览器 UA，并改为最多 8 跳的宿主管理重定向：逐跳接收 Cookie、支持相对 `Location`、跨 origin 清理 Cookie/Authorization，URLConnection 与 DNS fallback 均禁用内部自动重定向。
- Mihon 封面被归一化为保留来源 headers 的 `mihon:resource:`；相对与 protocol-relative thumbnail 可通过统一 source loader 显示。页面资源同时携带媒体类型提示。
- Mihon 详情中的未知页数当时以最多两个并发 worker 渐进预检并复用 `CachedBrowsableComicSource`；该普通章节正文预检已由 dev.78 / ADR 0062 撤销，synthetic gallery 的非空正文验证仍保留。
- Mihon 目录调用失败或为空时不再立即终止：只有 synthetic 章节真实解析出非空页面才接受 gallery 兜底；目录与页面均失败时保留原始目录失败为 suppressed 诊断。
- 新增重复资源 URI、插件私有持久下载、当时的 Mihon 页数预检、Venera WebP/UA/重定向及 Mihon gallery/封面契约回归；普通章节页数预检后由 dev.78 替代。

## 0.31.0-dev.62：漫画源分类、插件页签与 Mihon 章节结果闭环

- 漫画源管理中的启用来源按“原生 / Mihon / Venera”分区，并以分隔线隔开；Mihon 同一插件 family 的语言来源只显示当前语言或通用语言，其余语言在该页面默认折叠。折叠不改变安装记录、来源 identity、启用状态或信任粒度。
- Mihon/Venera 各自的管理页移除左右双栏，顶部仅保留“已安装 / 仓库”切换，内容区随页签整页切换。设备上的 Mihon 扩展迁入“已安装”页，使用独立刷新按钮与错误状态，不再和仓库加载共用 busy/error 区域。
- 保留来源启用顺序：原生与 Venera 在各自分区内可拖动，Mihon 以语言 family 为单位拖动，折叠的语言来源随 family 一起移动。
- Mihon 章节探测同时兼容 public/inherited 方法以及 Future、RxJava 1 `toBlocking().value/single/first`、RxJava 2/3 `blockingGet/blockingFirst/blockingSingle`。真实目录探测出现错误时不再被空候选掩盖为 synthetic 单章节。
- 空目录 gallery 兜底在详情阶段先实际解析页面；只有能得到非空页面列表才暴露 synthetic “正文”，并写入真实页数。普通远程章节的未知页数显示为“页数待加载”，不再误导为 0 页。
- 新增/更新漫画源信息架构、Mihon reactive adapter、空目录 page preflight 和折叠位置回归门禁。

## 0.31.0-dev.61：Reader/WebP 组合解耦与兼容插件双栏管理

- 修复 `apps/app/lib/reader_runtime.dart` 直接引用未导入 `SourcePool` 的编译错误。Reader session、transport、workspace、pipeline 与 streaming source 的装配迁入新 `packages/reader_runtime`；App 文件缩为兼容导出，生产依赖不再直接声明 `pipeline/sessions/storage/transport`。
- 修复 WebP 流式探测对 `parseWebpPrefixInfo` 与 `webpPrefixDeclaresAnimation` 的遗漏。两者由 `media` 包显式提供，WebP UI 不再依赖偶然的转出。
- 将超过 3300 行的 `webp_demo.dart` 迁入 `packages/local_media_ui`，按模型与预览、catalog/codec、静态图片播放器、页面、native WebP 播放器拆分；App 保留两行兼容 facade，单个实现文件均低于 1600 行。
- 漫画源管理首页只保留 Mihon/Venera 入口。每个生态自己的管理页改为固定双栏：左侧仅显示该生态已安装插件及启动失败/移除状态，右侧显示设备导入与仓库安装/更新。
- Mihon 仓库按包名中的插件 family 聚合多语言变体。当前界面语言优先作为默认可见项，其次 `all/multi`、英语；其余语言放入默认折叠的“其他语言”区域，不再把同一插件的所有语言版本平铺。
- 架构门禁改为读取新 package 实现而非 App facade，并新增 App 生产依赖泄漏、文件规模、双栏布局和 Mihon 语言折叠回归。

## 0.31.0-dev.60：Venera 登录、Mihon 章节探测与 Reader 流式闭环

- 严格沿用 dev.59 代码线；`vibevenera-master` 仅作为 Venera 账号和流式进度交互参考，没有替换 ZIC 的 runtime、下载、缓存或 Reader 所有权。
- Mihon 组合详情接口返回空章节时不再立即生成“正文”。runtime 会继续对详情对象与原始漫画对象探测独立章节目录，并依次兼容 `getChapterList`/`fetchChapterList`；空结果或明确的 unsupported 只表示继续探测，只有最终规范化目录为空才生成单章节兜底。真实章节仍保留 live `SChapter` 和稳定 wire identity。
- Venera `account` 现映射为统一来源账号协议：账号密码、按源声明顺序传递的 Cookie 字段、WebView 登录快照、退出登录和登录状态。网页登录回传最终 URL、标题、Cookie 与 localStorage；隔离 runtime 仍拥有持久化与来源回调，Presentation 只承担用户交互。
- App bootstrap 立即挂载内存 composition 与主界面，持久书架/缓存/下载服务在后台打开；恢复期间只显示顶部 2px 同步条，不再用“正在恢复书架”阻塞可操作界面。
- Reader 默认缩放比例下不创建会竞争横向手势的 `InteractiveViewer`，远程分页重新由 `PageView` 接管；只有显式缩放后才进入单页拖动/缩放。静态 PNG/JPEG/静态 WebP 不显示暂停与播放速度，动画能力由媒体探测或页面提示决定。
- 远程 WebP 直接绑定权威 `DownloadSession.ingress.source` 的增量 native cursor；`needMoreData` 等待 session committed bytes 推进而不是回退到完整文件。顶部控制栏分别显示恢复时已有前缀和本次网络新增进度，下载完成后仍沿既有 artifact/promote 生命周期收口。
- 修复 runtime worker 回归夹具只调用四个旧操作的问题：测试现在实际往返 settings 与 account 操作，再验证完整 operation 集合，不通过缩短期望绕过协议缺口。
- 新增 Mihon 章节探测、Venera 账号/login snapshot、Reader 手势/静态控制、WebP 增量 source 与双进度条的源码提取式门禁；Venera 账号加载与设置失败相互隔离，设置回调失败不会隐藏登录入口。

## 0.31.0-dev.59：Mihon 章节目录身份与 Venera 插件设置闭环

- 严格以用户上传的 `zic_v0.31.0-dev.58_fixed.zip` 为唯一基线。未合并此前 dev.58 归档或其他历史候选。
- Mihon 详情页保留插件返回的完整多章节目录，不再由单章节兼容路径覆盖。仅当真实章节列表为空时生成一个带显式 `synthetic` 标记的“正文”章节；非空目录不会调用 synthetic factory。
- Mihon runtime 在详情加载后按 opaque chapter ID 保存原始 `SChapter` 对象，阅读时优先复用，避免重建丢失扩展私有/运行期状态。runtime 重启或缓存缺失时重新拉取来源目录，并按 URL，或名称、章节号、汉化组和发布时间组合精确匹配；缺失和歧义均明确失败。
- 1.4 与 1.6 兼容 `HttpSource.fetchChapterList` 均重新执行扩展的 `prepareNewChapter(chapter, manga)`，确保多章节 URL、编号和来源自定义归一化在进入 ZIC 协议前完成。
- Venera runtime 新增 `loadSourceSettings`/`updateSourceSetting` 完整实现，映射 `switch`、`text/input`、`select`、`multiSelect` 与 `callback/action`；设置值使用类型保持的私有持久化，兼容 dev.58 的字符串布尔/数组旧值。
- 漫画源管理页现在为 Mihon 与 Venera 的 `ConfigurableComicSource` 都显示设置入口。Venera 不显示 Mihon Web 登录项；动作设置在用户显式点击期间可执行来源确认对话框中的非取消回调，并在页面反馈执行结果。
- 新增多章节不降级、章节稳定身份、双 ABI `prepareNewChapter`、Venera 官方形态设置枚举/持久化/动作回调、通用 adapter action kind 与依赖门禁回归。

## 0.31.0-dev.58：Mihon 分版本 ABI 隔离与 Venera 运行语义闭环

- Mihon 1.4 与 1.6 `extensions-lib` 不再进入 App runtime classpath。Gradle 在构建时分别解析上游固定 revision、提取 `classes.jar`、使用 Android D8 生成 dex asset，并写入长度/SHA-256 manifest；1.5 metadata 显式映射到兼容的 1.6 asset。
- activation 按 `extensionLib` 选择 ABI，并把扩展 APK 与对应 ABI jar 交给 child-first `MihonExtensionClassLoader`。`eu.kanade.tachiyomi.*` 只从插件 workspace 加载；AndroidX Preference 与 OkHttp/Injekt/协程等 common runtime 仍由隔离宿主进程单一提供并合并资源，修复旧 e-hentai 扩展覆盖 1.6 final `HttpSource` 方法的 verifier 失败。
- 两份动态代码文件都按 Android 14 要求在写入前标为只读、写后 `fsync`、长度/SHA-256 重验并原子提升。activation 分别预检 child plugin ABI 与 parent common runtime，不再把 API 版本冲突误报为入口构造失败。
- Venera 不再把宿主 bootstrap 的 strict directive 强加给来源脚本，并提供兼容的全局 `res` scratch binding；详情加载错误现在携带 operation 与受限 JS stack，便于定位真实源脚本。
- Venera 默认调用上限从 10 秒调整为 55 秒，为底层单次 15 秒连接 + 30 秒读取预算保留 10 秒桥接/脚本收尾余量，且仍低于 60 秒平台上限；超时会继续协作取消，并显示操作名与实际上限。
- 新增 Mihon ABI 路由/child-first、Gradle 双 ABI 资产闭包与故障注入、Venera legacy `res` 详情及 55 秒默认限制回归。

## 0.31.0-dev.57：只读 Mihon dex 与 Venera 分页/资源兼容闭环

- 修复 Android 14+ 拒绝从可写 APK 加载 dex：Mihon payload 先打开同目录 `.part` 的写入句柄，立即将路径设为只读，再通过已打开句柄复制、`fsync`、完成长度/SHA-256 重验并原子提升为 runtime `extension.apk`；类加载前再次确认只读，失败仍由 activation workspace 统一清理。
- 修复 `VeneraRuntimeDriver` 响应头泛型编译错误。响应适配改为接受 `Map<*, *>` 并逐项净化 String key 与可迭代值，同时兼容 `HttpURLConnection.headerFields` 的 nullable 泛型和 OkHttp 的非空 multimap。
- Venera browse 能力现在把 `load` 与 `loadNext` 都视为正式 loader。token 分页由隔离 runtime 按 source/query/options 保存，支持官方 e-hentai 等 `{comics, next}` 契约，不再在 activation 阶段误报无 browse capability。
- Venera 封面 URI 归一化为绝对 HTTP(S) 地址，普通封面可直接进入同一受控 Network/Cookie/response-limit/图片转换链；章节页面继续使用有生命周期的 `venera-resource://` token，不改变 Reader 或缓存所有权。
- Venera 详情和章节统一输出领域值 `vertical`；Dart adapter 同时接受旧 `topToBottom`、`webtoon`、左右方向长名与规范枚举，未知值仍明确失败。
- Venera source-key 静态检查只读取 `class ... extends ComicSource` 后的第一个类级 `key = "..."`，不再把 Picacg 方法内的 `let key` 等局部变量误判为冲突 metadata。
- 新增产品源码提取式 Kotlin/JavaScript 门禁：nullable/non-null response header 编译、Mihon APK 只读权限、Venera `loadNext` 两页推进、绝对封面资源、方向别名与方法局部 key 回归。

## 0.31.0-dev.56：Mihon payload Context 与 Venera 当前源兼容闭环

- 严格以 dev.55 为基线，并将用户提供的 `git_latest_two_commits.zip` 中 13 个对应文件原样覆盖后继续开发；保留其“读取设备已安装 Mihon 扩展”、Venera gzip/deflate 响应解码、扩展索引/UI 与生成 Android host 升级。
- Mihon activation 现在为 process-private APK 构建 payload 专属 `Context`：包名、`ApplicationInfo`、资源、assets、class loader、theme、LayoutInflater、偏好与文件/cache 目录均绑定到该扩展副本。运行时重新核对 APK 包名和 1.4/1.5/1.6 ABI，避免扩展资源或隔离存储错误表现为泛化 `activationFailed`。
- Mihon 入口兼容 Kotlin `object`、静态 `create/newInstance/getInstance` 工厂、`Context` 构造器和无参构造器；每个入口失败均携带具体类名与根因。Dart `ExternalPluginActivationException` 也保留 native cause，产品 UI 可直接展示可定位诊断。
- Venera browse 兼容当前 `explore` 数组/对象/`Map`、直接 loader，以及 `category.parts[].itemType/categories/categoryParams` 与旧 `target.attributes` 两类分类契约；动态 `optionLoader` 和静态 `optionList` 都转换为真实默认参数，不再仅因对象 key 存在却未识别容器而报告“no browse capability”。
- Venera 网络桥将 `Accept-Encoding` 收敛到宿主实际解码的 gzip/deflate，并继续按 `Content-Encoding` 有界解压。公共域名被系统 DNS 异常解析为空或回环/私网地址时，独立进程可通过受限 DNS-over-HTTPS 获取 A/AAAA 地址，再由 OkHttp 自定义 DNS 保留原域名 TLS/SNI；CNAME、回环、链路本地、私网和组播答案均拒绝。
- 新增从实际 Kotlin/JavaScript 产品源码提取并执行的 Mihon 入口构造、payload Context 编译、Venera 网络策略和 Venera bootstrap 合约门禁，以及 activation cause、当前分类形态和 DNS 过滤回归。Reader、下载、缓存、session/cancel 和专用 runtime process 所有权不变。

## 0.31.0-dev.55：Mihon 单一 ABI 提供者与 release 保留闭环

- 修复 Android release `checkReleaseDuplicateClasses`：`extensions-lib` 现在只作为非传递的 Mihon/Tachiyomi ABI AAR 使用，不再把其旧 POM 中的 Kohesive Injekt 依赖与当前 Keiyoushi common bundle 同时带入 App。
- 移除重复声明的 `androidx.preference:preference-ktx`。当前 pinned `extensions-lib` AAR 已提供该 ABI；宿主继续只显式提供 Keiyoushi 当前使用的 null2264 Injekt、协程、序列化、网络、解析与 QuickJS 运行库。
- 新增 Android 外部运行时依赖闭包检查，禁止重新引入官方旧 Injekt 或第二份 AndroidX Preference，并要求 `extensions-lib` 始终保持 `transitive = false`。
- 新增 consumer R8 规则，保留动态 APK 会引用但静态 App 图不可见的 Source、Preference、Injekt、RxJava、协程、序列化、OkHttp/Okio、Jsoup 与 QuickJS 二进制 API。
- Mihon activation 在创建 class loader 前预检核心宿主 ABI。缺失 Source/模型、Preference 或 Injekt 时明确拒绝 activation，不再延迟为来源空结果或不稳定反射错误。
- 新增 host ABI 缺失报告回归，并保持独立 runtime process、payload 重验、session/cancel、Reader、下载和缓存所有权不变。

## 0.31.0-dev.54：Android 依赖闭环与 Mihon runtime 清理

- 修复 `ExternalPluginController` 恢复 manifest 时调用不存在的 `File.isFile()` 所造成的 Dart 编译阻断。恢复阶段现在只接受插件私有目录中的普通 `.apk`/`.js` 文件，并拒绝目录、外部路径、符号链接和 `.part` 预览文件。
- `tool/configure_platforms.py` 现在同时配置 Android Internet 权限和宿主级 JitPack 仓库。它优先写入 `dependencyResolutionManagement.repositories`，否则写入生成宿主的 `allprojects.repositories`，兼容 Groovy/Kotlin DSL 且保持幂等；插件子工程也统一使用 canonical `https://jitpack.io`。
- 保持 Keiyoushi 当前 1.6 runtime-only 依赖坐标不变，但确保这些依赖由真正解析 `:app:releaseRuntimeClasspath` 的宿主仓库集合获取，不再依赖插件子工程局部 repository 对最终 App 配置生效。
- Mihon 每次 activation 使用包含 `driverId` 的独立 code-cache workspace，避免同插件同版本并行 activation 相互删除 APK、dex 或 native library。activation 失败立即清理；关闭时协作取消请求、关闭 source，并在真实任务排空后删除 workspace。
- 专用 runtime Service 启动时清理上次进程死亡遗留的 Mihon workspace。请求任务改为预注册的 `FutureTask`，关闭/取消发生在任务启动前也能完成 request result 与清理，不再留下未计数的运行时目录。
- 新增 generated-host Groovy/Kotlin repository 回归、manifest 非法 payload 恢复回归及 Mihon workspace 唯一性/陈旧目录清理回归。Reader、下载、缓存和 Home startup 所有权保持不变。

## 0.31.0-dev.53：Mihon/Venera 真实运行时与产品入口

- `plugin_host_bridge` 在既有 `:zic_plugin_runtime` 进程内注册 Mihon 与 Venera 原生 driver；Dart process host 继续拥有 payload 重验、session、取消、并发、响应上限与关闭策略，Kotlin 不复制这些所有权。
- Mihon APK 从 process-private 已验证副本加载，解析批准的 `Source`/`SourceFactory` 入口并兼容现行 1.6 suspend API 与旧 Rx API；browse/detail/chapter/resource 被映射到共用 protocol v1。图片请求优先复用扩展自己的 client、headers 与拦截器，无 client 时才使用平台 HTTP 后备。
- Venera JavaScript 在无 UI、禁用文件/内容访问和 DOM storage 的 process-private WebView 中运行；实现 1.6 `ComicSource`、Network/Cookie/Convert/Storage/HTML/APP/compute 兼容桥、最低宿主版本检查、数组/对象/`Map` 漫画与章节返回兼容、资源 HTTP 失败重试，以及受像素/响应上限约束的 `Image` 裁剪、旋转、拼接和输出桥。
- 漫画源管理新增 Mihon 仓库与 Venera 源仓库入口。下载、不可变 payload 提升、SHA-256/签名/ABI/source-key 检查、显式信任、安装/更新/回滚/移除及重启恢复由 `ExternalPluginController` 统一管理；启动失败直接显示，不伪装成空源。
- Mihon 入口使用当前仓库推荐的 `index.pb` 地址，并兼容 `repo.json`；发现阶段读取同仓库发布的完整 `index.json` companion，并解析当前 `extensionList.extensions` v2 对象及旧版数组，避免旧 `index.min.json` 的升级占位条目，同时不把 protobuf 依赖带入可执行插件边界。
- 外部源仍只作为普通 `BrowsableComicSource` 注入既有 catalog/cache/download/Reader 管线，不获得导航、Reader demand、页面 artifact 或缓存所有权。Home startup 已有核心服务阶段保持不变，插件恢复放在核心服务 ready 之后。

## 0.31.0-dev.52 — generation-aware Binder death and verified packet consumption

- Close the reported compile gap with explicit catalog imports in `runtime_service.dart` and the dedicated-entrypoint regression; declare the bridge test dependency directly instead of relying on transitive package visibility.
- Replace the reusable Android `ServiceConnection` flags with a generation-aware binding state. Each explicit bind gets a new generation and Binder death is observed through `linkToDeath`; stale callbacks from an older service cannot invalidate a newer explicit rebind. Service loss fails each active request once and never replays it.
- Abandon a binding generation when all queued callers time out before the Service connects, allowing a later explicit activation to bind again instead of remaining stuck behind a permanent `binding` flag. Connected-service request timeout does not tear down unrelated sessions.
- Split large-response packet files into a pure file owner with exact root/path/length/SHA-256 verification. The host verifies the digest while performing the one required file-to-codec read, deletes consumed or corrupt packets, and rejects path escape. Inline responses are digest-checked too.
- Add Android JVM regressions for stale service-death callbacks, explicit retry generations, closing callbacks, large packet consumption/deletion, corruption rejection and path confinement. Preserve Home trace, image/Reader ownership, process generations and fail-closed Mihon/Venera drivers.

## 0.31.0-dev.51 — Android dedicated runtime service bootstrap and Binder-safe transport

- Preserve the confirmed `runtime_service.dart` import fix and continue from the dev.50 process-generation endpoint without reopening that compile issue.
- Add a non-exported Android service in the `:zic_plugin_runtime` process. It starts a FlutterEngine with automatic plugin registration disabled and executes the retained `zicExternalPluginRuntimeServiceMain` secondary Dart entrypoint.
- Add a Dart bootstrap that attaches `AndroidExternalPluginRuntimeServiceHandler`, announces the new process generation, and remains fail-closed with no Mihon/Venera driver installed. Kotlin still does not own payload verification, session routing, cancellation or shutdown policy.
- Replace the main-process native fail-closed stub with a lazy bound-service client. Every activation/invoke/cancel/close request is sent once with a correlation identity; service death fails the outstanding request and never replays or transparently reactivates it.
- Add Binder-safe wire framing. Requests are capped below Binder's transaction limit; large binary responses spill to atomic app-private packet files and are decoded/deleted by the host process, avoiding base64 and oversized Binder transactions. Stale `.part`/`.packet` files are cleared on service start/destroy, and unclaimed large responses have a bounded retention timer.
- Add bootstrap/manifest/entrypoint regressions and ADR 0035. Concrete Mihon `Source`/`SourceFactory` loading and Venera JavaScript evaluation remain unavailable drivers inside the dedicated process.

## 0.31.0-dev.50 — compile closure and process-generation runtime service ownership

- Close report-32 compile blockers in product and test dependencies: stream SHA-256 now uses a real `Sink<Digest>`, runtime activation imports the handshake boundary explicitly, and affected tests import `dart:async`/domain `Failure` from their owning libraries.
- Add `ExternalPluginRuntimeServiceEndpoint` as the single dedicated-process dispatcher for Mihon/Venera activation, invoke, cancel, session close and process close. Exact method fields and plugin-format/method agreement are validated before the process host is called.
- Add an unforgeable runtime `processId` generation to every activation. Invoke/cancel/close must carry the same generation, so a service restart rejects stale sessions even when a session ID is reused and never auto-reactivates or replays the failed request.
- Add a Dart-side Android MethodChannel service handler that maps stable service/process errors while delegating all activation parsing, payload staging, session registry and teardown policy to the shared process host instead of duplicating it in Kotlin.
- Add process-service, stale-generation, joinable close, platform-channel and handler conformance tests plus ADR 0034. Concrete Mihon class loading and Venera JavaScript evaluation remain fail-closed driver work.

## 0.31.0-dev.49 — meaningful decode-target regression and process-entry payload ownership

- Fix the reported target-rebuild timeout by using a deterministic 2048×2048 VP8X canvas fixture. The regression now proves that the viewport change produced distinct downsample targets before asserting gapless replacement; a tiny 2×2 source correctly remains a no-op.
- Add strict Mihon/Venera process-entry activation parsing with exact schema fields, plugin-format identity, capabilities and runtime limits.
- Revalidate the inspected payload inside the isolated process, stream it into a process-private atomic copy, and pass only that verified copy to the ecosystem driver. This closes the verify-then-reopen path race.
- Add a process-owned runtime session registry with bounded activation, joinable teardown, source-key validation, cooperative cancel routing and no automatic request replay after process restart. Closing drivers continue to consume a session slot, and process shutdown cannot publish a partially activated session.
- Add payload mutation, staged-file lifetime, Venera source identity and process-restart regressions plus ADR 0033.

## 0.31.0-dev.48 — deterministic controlled-codec tests and drain-safe image teardown

- Close the repeated `local_image_preview_test.dart` shutdown stall at its lifecycle boundary. The plain-file zero-copy assertion is now a pure provider-routing test and never starts a platform `FileImage` decode.
- Extract `FlutterAnimatedCodec`/`FlutterAnimatedCodecFactory` from the controlled animation state machine. Production still uses `ui.instantiateImageCodec`; widget tests inject a deterministic codec so engine-thread WebP completion cannot strand the test platform.
- Publish controlled-animation readiness only after `WidgetsBinding.endOfFrame`, retain the previous frame until its replacement is visible, and dispose the retained frame when a generation is invalidated during presentation.
- Put every async image regression behind unconditional widget teardown. Failed assertions now cancel timers, dispose codecs/images and yield the event loop before the next test; cold Reader artifact polling uses the same bounded real-event deadline.
- Preserve Home startup trace and the dev.47 Mihon/Venera worker/platform-channel boundaries unchanged. Record ADR 0032; concrete isolated APK and JavaScript drivers remain downstream work.

## 0.31.0-dev.47 — isolated runtime worker, cooperative cancellation and platform backend channels

- Add one server-side `ExternalPluginRuntimeWorker` shared by Mihon and Venera isolated backends. It reparses protocol-v1 requests inside the isolation boundary, rejects unknown sources and duplicate active request IDs, sanitizes backend failures, tracks real work and owns deterministic teardown.
- Add cooperative request cancellation across raw runtime channels. A caller timeout sends best-effort cancellation when supported, while the host concurrency permit remains occupied until the underlying backend Future actually exits.
- Serialize immutable Mihon/Venera activation envelopes, approved capabilities and exact runtime limits across the platform boundary. Add Android host-side method-channel backends for activation, invoke, cancellation and close; the native bridge remains fail-closed until a dedicated APK/JavaScript service is installed.
- Add conformance regressions shared by both ecosystems for browse/comic/chapter/resource operations, unknown and duplicate identities, timeout cancellation, retained concurrency, joinable close and platform-channel serialization.
- Preserve the existing Home startup trace and the dev.46 local-image/cold-artifact lifecycle fixes unchanged. Record ADR 0031; concrete Mihon class loading and Venera JavaScript evaluation remain separate isolated-driver work.

## 0.31.0-dev.46 — single image-stream ownership, active-run artifact priming and raw runtime channel

- Close report-30's local-image test stall by removing the second manually resolved `FileImage` stream. Static image readiness now comes only from the renderer-owned `Image.frameBuilder`; the zero-copy file-routing regression verifies `FileImage` without waiting for a host codec and explicitly unmounts the provider.
- Yield the real event queue for host codec work in animation and cold-artifact widget regressions, then explicitly unmount animated players so codecs/timers do not leak into later tests or suite shutdown. Product ready still means a frame was actually presented.
- Prime promoted page artifacts at authoritative `DownloadSession.beginRun`, before ephemeral workspace restore, while keeping pages join-only. Add coverage for observers attached after a run already became active.
- Add a raw, versioned external-plugin runtime message channel and handshake around protocol v1. Every call serializes across the boundary, validates response/request identity, rejects duplicate source identities and exposes joinable close without leaking Reader/download/artifact objects.
- Preserve the existing Home startup trace unchanged, add regressions and ADR 0030. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.45 — versioned external runtime protocol and shared source adapter

- Close report-29's constant-evaluation blocker by keeping `ExternalPluginRuntimeLimits` const-capable while validating `Duration` positivity at executor/session activation instead of invoking relational operators in a const initializer.
- Add one versioned, ecosystem-neutral request/response protocol for browse, comic, chapter and binary resource operations. The wire schema accepts only bounded method-channel-safe values and never exposes Reader, demand, `DownloadSession` or artifact APIs.
- Adapt isolated Mihon and Venera runtime connections through one `ExternalPluginRuntimeSession` into ordinary namespaced `BrowsableComicSource` instances, with strict source/comic/chapter/page identity validation.
- Enforce invocation timeout, response bytes and concurrency again at the host boundary. A timeout no longer releases its permit until the underlying isolated call actually exits; queued calls cannot steal or overbook transferred permits.
- Make concurrent session close calls join one shutdown, signal the isolated connection before draining real work, reject queued work deterministically and close failed handshakes.
- Preserve the existing Home startup trace unchanged, add protocol/runtime lifecycle regressions, and record ADR 0029. Concrete Mihon class loading and Venera JavaScript evaluation remain isolated backend work.

## 0.31.0-dev.44 — visible-frame readiness, authoritative artifact priming and plugin execution contracts

- Close the report-28 compile blocker with the explicit `ResourceCacheFileByteStore` composition capability. File lookup and durable invalidation now share one statically valid owner instead of relying on promotion to the intersection of unrelated nullable interfaces.
- Make local WebP readiness mean an actually presented first frame rather than container validation. Cold-codec and target-rebuild regressions use the packaged animation fixture and retain strict visible-frame/no-black-gap assertions.
- Prime promoted-artifact reads when the authoritative replacement `DownloadSession` enters queued/receiving state. Page consumers still only join that single read; they do not create cache or network demand. Promotion waiting now checks session state before and after listener attachment.
- Extend Android Mihon pre-load inspection with normalized extension entry classes, while continuing to forbid class loading during inspection. The trust gate rejects executable activation metadata that lacks an entry class.
- Add separate immutable-payload execution request contracts for an isolated Mihon backend and a bounded Venera JavaScript backend, including invocation, response, concurrency and runtime-heap limits. Concrete engines remain downstream adapters and cannot bypass inspection, trust or session identity validation.
- Preserve the existing Home startup trace without adding new cold-start work, add queued-read and runtime-request regressions, and record ADR 0028.

## 0.31.0-dev.43 — compact cover manifest, attributable Home startup and Android Mihon metadata

- Close the external dev.42 compile blockers in product code: encoded memory sources no longer use a runtime value in a const initializer; durable file-store capabilities are explicitly narrowed; chapter bulk projection parenthesizes nullable async fallback correctly; and local animation branches require non-null encoded bytes before constructing byte-owned players.
- Replace per-cover warm metadata reads with one storage-owned `response-manifest-v1.json`. Per-entry journals remain for atomic crash recovery/migration, target file length is still verified, LRU touches are batched, and warm hits continue to return immutable file references without whole-file Dart copies.
- Add a monotonic Home startup trace covering Flutter bootstrap presentation, service-open phases, cover request, encoded source origin/length and first decoded frame. Encoded sources now distinguish memory, ordinary local files and durable cache files explicitly.
- Add the Android `plugin_host_bridge`: Mihon APK archive inspection runs off the platform thread and reads package, current signer SHA-256, version code and supported extension ABI metadata through `PackageManager` without class loading.
- Make bounded Venera inspection derive UTF-8 metadata and SHA-256 from one immutable byte snapshot, preserving repository/script key agreement and non-execution.
- Add manifest reopen/migration, encoded-origin, Home telemetry, Venera invalid-payload and Android bridge regressions, plus ADR 0027.

## 0.31.0-dev.42 — file-backed Home covers, lazy startup and concrete plugin inspection

- Correct the cold-start diagnosis: mount Flutter immediately with a startup surface, remove eager restoration of every indexed offline page, avoid a duplicate application-support path lookup, bulk-load read-state projection in one query, and project Home download badges from one SQLite index scan without materializing sessions or statting page files. Exact page commands alone restore artifacts.
- Add a file-backed encoded-image contract. Durable cover hits validate the exact key, expiry and length, then pass the immutable cache file to `FileImage` without whole-file `readAsBytes`, startup hash recalculation or per-hit metadata flush. Access recency is batched until store close, and in-process file locations are reused.
- Let ordinary local static images use the same file-provider path when no Reader/pipeline loader owns the request. Android content URIs, animations and Reader pages retain controlled byte/session fallbacks. The implementation avoids Dart-heap copies but does not claim absolute storage-to-texture zero copy inside platform decoders.
- Publish Flutter animated `ready` only after the first frame has actually been presented, retain the gapless target-rebuild invariant with a real packaged WebP fixture, and keep the cold promoted-artifact regression state-driven.
- Add concrete Mihon APK and Venera JavaScript payload inspectors over one immutable local payload: streaming SHA-256, exact-length checks, metadata-only APK parsing boundary, bounded non-executing Venera key discovery, and repository/script key agreement. Executors remain separately sandboxed adapters.
- Add file-backed cache, batched-touch, direct local-file provider, lazy artifact restore and plugin-inspection regressions, plus ADRs 0025 and 0026.

## 0.31.0-dev.41 — direct promoted reads and gapless cold decode

- Fix the reported `static_demo.dart` compile failure by importing the downloads-owned Reader page identity adapter rather than relying on a re-export side effect.
- Let a reopened Reader consume one exact immutable read of an already-promoted page artifact while the replacement `DownloadSession` continues its normal seal/promote path in the background. The page and cache transport share that read through a downloads-owned pool, removing cache-to-ephemeral-copy and re-read from first-frame latency.
- Stream background cache handoff in 64 KiB chunks and use the exact DownloadId/length as the resume validator, avoiding a second whole-page hash and giant single-chunk copy on the UI isolate. Cache read failures now fall back through the normal session/origin path with trace evidence.
- Keep the currently presented Flutter animated frame during target-only codec rebuilds and replace it only after the new frame is presented, eliminating the black gap caused by eager frame disposal. Encoded-byte changes still invalidate the frame.
- Extend transition replay with durable artifact read duration and consumer attribution, preferring the Reader-direct event when both direct consumption and session-copy events exist.
- Preserve the strict midpoint invariant before gesture release while allowing the old page to be evicted after settling; the regression still forbids a loaded page remount. Add cold-open, coalesced-read, chunking, fail-open cache, Flutter codec phase and gapless-target regressions, plus ADR 0024.

## 0.31.0-dev.40 — managed artifact capability and deterministic transition replay

- Close the reported App compilation failure without widening every chapter-download implementation: add the explicit
  `ManagedChapterDownloadService` composition capability, implemented by the memory and persistent services, and use it
  at the durable App root where artifact maintenance is required. The narrower `ChapterDownloadService` remains valid
  for UI/test adapters that do not own promoted artifacts.
- Replace the Reader midpoint regression's fixed-pixel assumption with state-driven gesture progression. The test first
  proves the target host entered the render tree while the original page is still current, then crosses the actual
  midpoint and verifies neither loaded host was disposed or recreated. Product keys and ownership are not weakened.
- Add deterministic `ReaderTransitionTraceAnalyzer` replay over the existing transition/artifact/decode/upload/present/
  first-frame/host-lifecycle trace chain. It reports cache versus origin selection, host-remount evidence, phase durations,
  missing evidence and the dominant measured phase without changing demand, retention, cache or eviction policy. The
  replay distinguishes transition revision from the revision that produced the presented frame and emits a JSON-ready
  report, so a preloaded neighbor is measured as zero transition wait instead of being attributed to later swipe work.
- Move Reader page DownloadId/trace identity construction into `downloads`, add rapid-swipe, incomplete-trace,
  host-remount and managed-capability regressions, plus ADR 0023 and updated handoff
  rules for evidence-driven retention work.

## 0.31.0-dev.39 — compile closure, transition attribution and permissioned plugin hosts

- Close the reported dev.38 Dart compilation regressions: durable `Uint8List` restoration is explicitly narrowed back
  to the caller's generic type, byte-store maintenance uses its promoted capability interface, and the stable Reader
  page host constructor accepts the `key` supplied by `PageView`.
- Move the production durable response-cache composition into one reusable storage-bridge factory and add an app-level
  two-start regression that restores both source-card and comic-detail covers through the real file-backed cache without
  invoking the raw source after restart.
- Add revision-correlated Reader/pipeline telemetry for page transition coverage, page-host mount/dispose, first-frame
  delay, artifact-cache versus origin bytes, decode demand/start and upload demand/start. Demand revisions are captured
  when work is created so a later plan cannot relabel queued work.
- Add the dependency-light `plugin_host` package. It gates Mihon-compatible APKs by repository, payload, package,
  signer, version and extension ABI metadata, and gates Venera-compatible JavaScript by repository, payload, stable
  source key and explicitly allowed capabilities before any executor receives code.
- Add plugin failure quarantine and a runtime registry that owns activated sessions, deactivation and shutdown while
  rejecting source identities already registered by another plugin. APK/Kotlin and JavaScript execution remain separate
  executor interfaces and are not claimed by this iteration.
- Add regressions for real cache restart, artifact-origin attribution, midpoint host preservation, demand/start/frame
  revision ordering, plugin gate rejection before execution, quarantine, runtime source validation and cross-plugin
  identity collision cleanup.

## 0.31.0-dev.38 — durable cover cache, stable Reader hosts and plugin catalog seam

- Persist complete `imageBytes` responses through an injected `ResourceCacheByteStore`. The file implementation stores
  the full cache key, expiry, content length and hash under the durable app root, applies bounded LRU trimming and
  restores covers before invoking a source loader after process restart.
- Extend the standard image-response TTL to seven days while preserving exact namespace invalidation, revision-aware
  identities and explicit refresh. Graceful cache shutdown now rejects new work but drains already-owned requests and
  persistence writes instead of invalidating a cover that completes during exit.
- Keep Reader page and zoom hosts keyed by stable asset identity. Crossing the PageView midpoint updates the current
  role and resets page-local zoom without disposing/recreating the loaded media child, eliminating the observed
  neighbor-page return to black/loading caused by role-key remounts.
- Add format-neutral Mihon extension and Venera JavaScript repository catalog models, strict index parsers, namespaced
  external source identities and an explicit plugin-session lifecycle boundary. Venera parsing accepts both the
  documented `filename` spelling and the current repository's `fileName` plus declared `key`; APK/Kotlin and JavaScript
  execution remain separate future sandbox hosts rather than entering catalog, Reader or download ownership.
- Include durable response bytes in unified cache inspect/trim/clear reporting and Download Manager presentation without
  bypassing page-artifact busy/ownership rules.
- Add regressions for process-reopened cover reuse, close-time persistence draining, source-revision separation,
  durable store expiry/invalidation/LRU maintenance, midpoint page-host preservation and external plugin identity parsing.

## 0.31.0-dev.37 — promoted Reader artifact cache handoff

- Persist exact Reader page bytes only after the authoritative `DownloadSession` reaches `promoted`. A package-owned
  `PromotedArtifactCacheHandoff` observes session state and drains commits before the ephemeral Reader workspace is
  removed; Presentation does not choose pages, start downloads or own a private byte cache.
- Add `ArtifactCacheStore` and `ArtifactCacheTransport` in `downloads`. A new Reader session first checks the durable
  page-artifact tier and falls back to the transport selected by `LiveCoordinator`; duplicate URI identities bypass the
  cache and range reuse requires a content-derived validator.
- Make persistent and memory chapter services expose page-granular artifact read/commit operations. Durable handoff
  writes still pass through `DownloadJob -> DownloadSession -> seal -> promote` and the existing index/`CacheOps`
  maintenance path instead of copying files or mutating the index from App code.
- Keep `resource_cache` dependency-light. It continues to own reusable source-response policy and artifact maintenance
  coordination, while `DownloadId`-specific storage remains in `downloads`.
- Remove the requested negative-TTL assertion from `ResourceCachePolicy`. Repair failed in-flight request coalescing so
  one source failure is delivered only through the caller-owned futures rather than an extra unobserved derived future.
- Restore the Download Manager empty state when cache statistics are present but no chapter/whole-comic tasks exist.
- Add regressions for failed request coalescing, exact cache hits, range validators, ambiguous URI fallback, promoted
  handoff, in-memory artifact clearing and persistent reuse after service reopen.

## 0.31.0-dev.36 — unified resource cache and restored pipeline ownership

- Correct the `0.30.0-dev.35` cache boundary. Remove the App-owned `CoverMemoryCache` and competing `ReaderPageBytesCache`; Reader presentation no longer warms current/adjacent page bytes or enables implicit page retention outside pipeline policy.
- Add the workspace-level `resource_cache` package. Cover/image responses, comic details, chapter metadata and search results share one global/per-kind budget, TTL, in-flight coalescing, LRU eviction, exact source-composite namespaces and stale-response suppression after refresh/clear.
- Add `CachedBrowsableComicSource` in catalog. Explicit source refresh invalidates the relevant search or comic namespace; chapter page `loadResource` remains a raw pass-through so encoded pages continue through demand/session/artifact ownership.
- Move chapter artifact downloads and durable whole-comic scheduling out of `apps/app/lib` into `downloads`. Move runtime network/power and JSON persistence adapters into `downloads_bridge`; the queue now explicitly closes owned environment adapters after draining work. Download Manager stays a presentation/command surface over package interfaces.
- Model partial offline chapters as independent page artifacts plus separately cached chapter metadata. `ResourceCacheCoordinator` owns shared maintenance policy and reports both planes without turning a chapter into an all-or-nothing cache entry or leaving capacity thresholds in Presentation.
- Make the memory fallback mirror production artifact semantics: each completed page is retained immediately, cancellation/failure preserves the downloaded subset, retry skips retained pages, and trim/clear evicts page records rather than whole chapters. Folder imports persist their first page as explicit cover metadata; a missing remote cover no longer silently routes a chapter page through the response cache.
- Keep cache identity construction in package adapters. App composition injects an existing coordinator unchanged, and does not construct `ResourceCacheKey` values or replace an injected maintenance policy.
- Restore Reader page-role remount semantics required to reset stale zoom and remove the invalid stable-page-identity regression. Fix the reported cache-maintenance type promotion and invalid imported-page cover field.
- Add regressions for cache namespaces, per-kind statistics, refresh supersession, clear-during-in-flight behavior, catalog cache/raw-page boundaries and platform queue persistence.

## 0.30.0-dev.35 — home decomposition and bounded media caches

- Split the 3300+ line Home shell into durable `HomeLibrarySession`, Home/Bookshelf view composition, reusable cover/shelf Widgets and a smaller navigation/use-case coordinator. Enforce a first-stage line budget on `demo_home.dart`.
- Add bounded, concurrent-load-coalescing LRU cover bytes instead of the previous unbounded process-lifetime map. Cover Widget decode targets now follow rendered size/DPR and retain the previous frame during replacement.
- Add a bounded Reader encoded-page cache with current/next/previous warmup, shared in-flight loads and obsolete-warmup cancellation. Stable page keys and implicit adjacent retention avoid remounting media solely on page-role changes.
- Expose persistent chapter-cache usage, trim and clear through Download Manager while keeping artifact/index ownership in storage and `ChapterDownloadService`. Completed/download/Reader state is not owned by the cache UI.
- Add deterministic cache, eviction, warmup, session projection, cache-maintenance and page-identity regressions. This iteration does not move native decode/frame/texture ownership into the App.

## 0.29.0-dev.34 — source migration candidate comparison

- Add an authoritative pre-write comparison for cross-source comic migration. The current and target works are shown side by side with cover, authors, source/native identity, reading direction and chapter counts.
- Add catalog-owned migration evidence: normalized title/author overlap, exact and sequence-only chapter counts, unmatched source/target chapters, chapter-pair samples and explicit risk flags.
- Require an explicit identity/risk acknowledgement before the existing conservative copy flow can continue. The comparison performs no durable writes and does not weaken target chapter identity verification.
- Cache each comparison cover load for the dialog lifetime so checking the acknowledgement box cannot repeat a remote cover request.
- Add catalog and Widget regressions for risk evidence, chapter samples, source/target identities and the disabled-before-acknowledgement confirmation action.

## 0.28.1-dev.33 — download manager OOM and queue shutdown repair

- Restore the missing `index++` in Download Manager's chapter-task list expansion. The old loop never advanced once at least one chapter snapshot existed, causing unbounded Widget construction and eventual process/WSL OOM.
- Close `WholeComicDownloadQueue` by first cancelling and draining active chapter work, then publishing the resumable final queue state, cancelling environment signals and closing the queue store/stream.
- Replace the affected chapter-download, library and source-browser tests with bounded frame waits and explicit route/widget teardown supplied in `apps.zip`; no product interaction is changed to satisfy those tests.
- Add a Dart structure gate that rejects conditional C-style `for` loops with an empty update clause, catching this OOM class before Flutter execution.

## 0.28.0-dev.32 test-harness correction — no product behavior change

- Advance simulated frame time while waiting for popup routes, route transitions, enabled buttons and refresh results instead of looping with zero-duration pumps.
- Wait for the Reader speed option to become hit-testable without changing the Reader speed UI again.
- Make paused whole-comic queue persistence assertions tolerant of an already-returning page while still proving that a restored paused job starts no new chapter.
- Release blocked test page loaders during teardown so a failed assertion cannot leave download services and Flutter test channels waiting indefinitely.
- Product code and package versions remain unchanged from `0.28.0-dev.32`.

## 0.28.0-dev.32 — durable whole-comic queue and runtime policy signals

- Replace the route-owned sequential whole-comic loop with `WholeComicDownloadQueue`, a durable JSON-backed
  scheduler keyed by exact `sourceId + comicId`. Restored jobs keep their chapter catalog and completed set;
  a process interruption converts an in-flight job back to queued work without taking ownership away from
  the existing per-chapter download service.
- Add global chapter concurrency limits, pause/resume, cancel/retry and queue-record removal. Duplicate enqueue
  requests coalesce while a job is active, and terminal chapter artifacts are re-inspected before scheduling.
- Add network and power gates. The queue can require an unmetered connection or charging, suspends active
  chapters when a condition becomes false, and resumes through the same `ChapterDownloadService` when the
  condition becomes valid again.
- Add the `runtime_bridge` Flutter/Android plugin. It reports validated network availability, Android metered
  state and battery charging state through versioned method/event channels; unsupported hosts retain the
  explicit injectable fallback instead of becoming another download owner.
- Extend Download Manager with a durable whole-comic queue section, queue policy configuration and per-job
  pause/resume/cancel/retry/remove actions while retaining the existing authoritative chapter task section.
- Restore the missing exhaustive bookshelf sort label that blocked App compilation, and replace the clipped
  Reader speed popup with a centered bounded dialog whose five options remain hit-testable on small windows.
- Add deterministic queue regressions for concurrency, policy waiting, policy loss during an active chapter,
  paused-job restoration, JSON restoration and Download Manager queue controls.

## 0.27.0-dev.31 — cover management and whole-comic downloads

- Restore management actions to each cover: delete at the upper-right and category migration through a
  popup at the lower-right. Remove the duplicate single-selection action surface; long-press starts
  source-composite multi-selection and the separate batch bar only owns batch move/copy/clear/delete.
- Preserve custom gallery ordering with a dedicated drag handle so reordering does not compete with the
  long-press multi-select gesture. Keep sort and category migration as bounded popup menus rather than
  bottom sheets.
- Make details subscribe to authoritative `ChapterDownloadSnapshot` state. A chapter keeps its spinner
  after route recreation, uses its own title and page denominator, and leaves the cover waterline
  immediately on completion.
- Add whole-comic download to the shared local/remote details header. It resolves the catalog once,
  downloads incomplete chapters sequentially through the existing chapter service, stops after
  cancellation, and preserves per-chapter task ownership in Download Manager.
- Project an active chapter or whole-comic task onto the shared cover; completed tasks use only a compact
  offline badge. Download Manager promotes the chapter name and omits the progress bar for completed
  tasks.
- Remove source/progress rows below covers, overlay the comic title at the lower-left, and keep reading
  progress in details. Coalesce rapid Home/History/Bookshelf/Source cover taps by exact source-composite
  route identity.
- Repair small-screen Reader speed-menu reachability, restore-unread ListTile material ownership, remote
  retry/pull-refresh controls and stable management interactions without changing product semantics only
  for tests.

## 0.26.0-dev.30 — migration diagnostics and interaction reliability

- Upgrade SQLite to schema version 6 by adding durable acknowledgement timestamps to
  `library_migration_issue`; pending and acknowledged records remain queryable without deleting or
  rewriting ambiguous legacy state.
- Add a Bookshelf Migration Diagnostics surface with refresh, selectable details, JSON clipboard
  export, pending/all filtering and individual or bulk acknowledgement.
- Keep the separate local/remote details owners while splitting chapter open and download locks;
  coalesce concurrent manifest persistence for the same source-composite chapter.
- Replace the restore-unread `Dismissible` lifecycle with a non-destructive right-swipe action so the
  row never leaves the chapter list while read state is persisted.
- Keep Reader controls at their final overlay positions while fading, making pause/speed/rotation and
  other controls hit-testable as soon as they are shown.
- Replace fragile bookshelf sort and category-move popup menus with explicit bottom-sheet choices and
  stable interaction identities; open Download Manager synchronously before refreshing snapshots.
- Repair reported cover/shelf fixtures, download/open ownership regressions, remote pull-refresh/retry
  interaction paths and schema-6 acknowledgement migrations without weakening product assertions.

## 0.25.0-dev.29 — authoritative download management and UI regression repair

- Add `ChapterDownloadSnapshot` and a common task lifecycle (`idle`, `downloading`, `complete`,
  `failed`, `cancelled`) to the chapter download boundary, including exact source-composite identity,
  comic/chapter labels, completed/total pages, received/total bytes and copyable failure details.
- Derive persistent progress from the existing `DownloadRegistry`, `DownloadSession` and promoted
  artifacts. Keep terminal phases authoritative while late progress callbacks drain, and preserve
  partial artifacts for retry/resume.
- Add a Download Manager reachable from Home and Bookshelf with per-chapter cancel, retry and
  confirmed offline-file deletion. Deleting bytes deliberately retains saved comics, chapter
  metadata, reading progress and read state.
- Project aggregate chapter progress onto the shared Home/History/Bookshelf cover component. Show a
  dimmed bottom-up waterline only while incomplete; restore the cover and show a compact offline badge
  when all known pages are durable.
- Fix missing-cover records so a failed/absent cover becomes a stable placeholder rather than a
  synchronous Widget-build exception.
- Mark a chapter read before opening Reader, remove the duplicate details title, make source
  management visibly reachable, and give sort/category/retry controls stable interaction identities.
- Make Reader pause/continue rebuild from its playback notifier and keep the existing media pipeline.
- Add deterministic cancel/retry/delete and Download Manager regressions, plus stronger Dart structure
  checks for nested duplicate named arguments and product contracts.

## 0.24.0-dev.28 — source-composite durable library schema

- Migrate SQLite to schema version 5 so imported chapters, reading progress, comic preferences and
  chapter read state use source-composite primary keys rather than source-agnostic native IDs.
- Carry `sourceId` through `ReadingProgress`, `ComicPreference` and `ChapterReadState`, with explicit
  fallback decoding for legacy JSON and source-aware Store point queries/removals.
- Upgrade schemas 1–4 transactionally. Resolve legacy chapter-owned data from its imported chapter;
  resolve ambiguous remote preferences deterministically and persist an auditable
  `library_migration_issue` record instead of overwriting or silently dropping state.
- Remove cross-source native-ID conflict guards now made obsolete by composite storage. Two sources
  can retain the same comic and chapter IDs with independent progress, preferences and read state.
- Preflight every exact cross-source chapter match before the first durable write; merge target comic
  preferences and preserve existing target progress/read state instead of overwriting it with source state.
- Run `PRAGMA foreign_key_check` before committing a legacy schema upgrade so an invalid composite
  ownership graph rolls back rather than becoming the active library.
- Make Home/history/source cards and details chapter/read/download Widget keys source-composite so
  Flutter state cannot be reused across equal native IDs from different sources.
- Fix the reported `void` callback conditional returns and type-safe legacy `SavedComicRecord` list
  decoding without weakening product tests.
- Add schema 4→5 ambiguity-reporting, duplicate-native-ID isolation and legacy JSON fallback
  regressions; make legacy schema preparation recover development databases whose version marker was
  written before every table existed.

## 0.23.0-dev.27 — two detail owners, whole-comic shelf, durable chapter downloads

- Replace the single stateful details owner with `RemoteComicDetailsScreen` and
  `LocalComicDetailsScreen`, while reusing the same header, preference/category controls, chapter
  rows, error panel and pull-to-refresh scaffold.
- Centralize exact `sourceId + comicId` routing: an unsaved source work stays remote; durable comic
  metadata or chapters route the same source work to local details.
- Add `SavedComicRecord` and SQLite schema version 4 so a whole comic can be liked, collected or
  added to the shelf without importing an arbitrary chapter. Persist a lightweight source chapter
  catalog for the local details page.
- Make the primary chapter trailing action a durable offline download. Persist promoted page
  artifacts outside the Reader session workspace and reuse complete offline bytes after restart;
  the in-memory fallback also owns actual page bytes before reporting completion.
- Add conservative cross-source copy migration for whole-comic preferences plus exact
  title-and-sequence chapter matches. Search the selected target source by the current title, let the
  user choose a candidate (with manual native-ID fallback), fetch target manifests anew, clamp
  migrated progress, copy read state, retain the original source and never copy source URLs or
  offline bytes.
- Use source-aware comic identities for aggregation, management selection, category insertion,
  custom drag targets and Widget keys. Guard legacy native-ID collisions instead of overwriting the
  current preference/chapter/read tables.
- Fix the missing `ImportedChapterRecord` import reported by the compiler and replace fragile
  indefinite animation settling/off-screen taps with state-bound product regressions.
- Replace the framework multi-tap recognizer dependency with a Reader-owned tap window so double-tap
  zoom keeps the real gesture path without leaving a pending test timer.

## 0.22.0-dev.26 — unified source-aware comic details and pull refresh

- Replace the separate remote details presentation with one `UnifiedComicDetailsScreen` used by
  Comic Sources, Home updates, reading history and Bookshelf routes.
- Merge the complete upstream source chapter catalog with persisted library entries by
  `sourceId + chapterId`; retain saved chapters that temporarily disappear upstream and never
  import newly discovered chapters until the user opens or explicitly adds them.
- Add pull-to-refresh and an app-bar refresh command. Source manifests and local-folder snapshots
  refresh through their owning boundaries, then reconcile into the same aggregate projection.
- Persist remote comic authors and description in backward-compatible chapter JSON so a Home/history
  details route retains the same metadata and cover as the source route before its network refresh.
- Keep read/dimming, restore-unread swipe, shelf/like/favorite/category actions, source filtering,
  chapter ordering, selectable diagnostics and Reader opening behavior identical across entry routes.
- Fix the missing domain model import that caused `Comic`/`Chapter` compilation failures in the App.
- Drain the Flutter double-tap recognizer timer after the real two-tap Reader zoom regression instead
  of weakening or removing the product gesture assertion.
- Add regressions for shared source/Home details, non-persisting pull refresh, metadata persistence,
  source-aware chapter state and legacy JSON compatibility.

## 0.21.1-dev.25 — Android source networking and copyable diagnostics

- Repair generated Android hosts by idempotently adding `android.permission.INTERNET` to the main
  manifest after `flutter create`, before Android builds, and before the repository Android runner.
- Add `tool/run_android.sh` so local runs use the same host preparation path as APK builds.
- Add a bounded HTTP connection timeout, source user agent, complete socket OS-error details and one
  short retry for transient MangaDex network failures.
- Replace truncated source errors with a clean diagnostic card containing a focused summary,
  actionable guidance, scrollable `SelectableText`, long-press selection and one-tap full copying.
- Add copy actions to secondary source failures without weakening retry or source-state behavior.
- Replace the unavailable `WidgetTester.doubleTap` call with two real timed taps while preserving the
  Reader zoom assertion and product gesture path.
- Add regressions for DNS failure presentation/copying, MangaDex transient retry and generated-host
  permission idempotence.

## 0.21.0-dev.24 — remote comic source browser

- Add a third `漫画源` application destination with a top source-management action and a bottom
  enabled-source switcher.
- Add catalog-owned remote browsing contracts, searchable/paged source UI, source details and
  chapter actions.
- Add a first-party MangaDex source using its API and MangaDex@Home page manifests, restricted by
  default to English safe/suggestive results.
- Route saved/opened remote chapters through `ImportedChapterRecord`, the durable library and the
  existing Reader DownloadSession/artifact pipeline.
- Persist source enablement and order in SQLite schema version 3, including schema 2 migration.
- Persist source-provided page IDs independently of rotating remote delivery URLs so refresh keeps
  the same reading page and sub-page offset.
- Retry transient comic-detail failures in place and bound remote metadata/cover response bodies
  before buffering them in memory.
- Add fixture transport tests, source-page widget tests, source preference persistence/migration
  tests and remote URL-rotation reconciliation coverage.
- Keep Mihon-compatible plugin runtime support as a later isolated adapter rather than embedding
  Android extension code into the Flutter UI process.

## 0.20.0-dev.23 — library management and immersive Reader controls

- Remove the Home local-directory maintenance panel while retaining folder import and the
  catalog/source refresh contracts outside the primary product surface.
- Reuse the same fixed-size `ComicCoverCard` for Home update/history rails and the Bookshelf
  gallery, including centered exact-width grid layout instead of stretched covers.
- Keep custom sorting in the selected gallery/list view; add a view toggle, long-press cover
  dragging in gallery management mode, and reorderable rows in list management mode.
- Add category-scoped comic insertion plus management selection with move, category membership,
  copy-info and confirmation-gated deletion; visually isolate the destructive action.
- Remove duplicate shelf labels and selected-chip checkmarks, and collapse diagnostics behind an
  explicitly secondary Home section.
- Start Reader in immersive mode with hidden top/bottom controls; tapping reveals page slider,
  animation pause/speed, rotation, favorite and chapter-cache actions.
- Add pinch/pan and double-tap zoom, disable page swiping while zoomed, and reset stale zoom when
  navigating away from a page.
- Route GIF and WebP pause/speed through the existing player ownership path, retaining download
  identity, telemetry, native fallback and viewport-aware decode raster selection.
- Add Flutter regressions for shared cover geometry, custom gallery drag ordering, category add/
  move actions, Reader controls, rotation and zoom reset.

## 0.19.0-dev.22 — comic-level library aggregation

- Fix the catalog and SQLite library test files so all registrations remain inside
  `main()`, restoring Dart test loading without weakening product assertions.
- Move the chapter read/unread gesture key onto the owning `Dismissible` and use a
  deliberate 18% non-destructive threshold, so right-swipe reliably restores unread.
- Add persisted `comicTitle` and chapter `sequence` metadata with backward-compatible
  JSON decoding for existing imported-library records.
- Preserve aggregate identity, title and sequence when a local directory chapter is
  rescanned, while replacing only the refreshed source revision and page snapshot.
- Add `LibraryComic` as a catalog projection that groups local or remote chapters by
  comic identity, selects cover/latest/resume chapters, and exposes aggregate page data.
- Drive Home, Bookshelf, custom ordering, categories, deletion, cover cards and details
  from comic aggregates while retaining per-chapter refresh, progress and read state.
- Add catalog, SQLite and Flutter regressions for multi-chapter grouping, preference
  lifetime, chapter selection and the repaired read-state transition.

## Unreleased — Android home, bookshelf, and comic details

- Add Android-first Home and Bookshelf destinations backed by the durable local library.
- Add update and reading-history cover rails, animated cover bytes, and download waterline progress presentation.
- Add local/remote and custom-category filters, management deletion, standard sort modes, and persisted custom drag ordering.
- Add persistent liked, in-shelf, collected, category, and chapter-read state with SQLite schema v2 migration.
- Add comic details with chapter order reversal, dimmed read state, and swipe-right restore-to-unread behavior.
- Keep local folders without metadata on the direct Reader path while retaining a details route for metadata-capable sources.
- Replace stale App-level PNG fixtures with complete PNG data and stabilize keyed smoke-test discovery.

## Unreleased — persisted local-directory refresh

- Add bridge protocol 3 and `scanImageDirectory` for rescanning a persisted Android SAF
  tree without reopening the picker; desktop refresh reuses the stored directory path.
- Derive imported Reader page IDs from stable source identities instead of page indexes.
- Reconcile memory and SQLite reading progress to the same source when refresh inserts or
  removes earlier pages, and clamp only when the current source disappears.
- Add per-chapter refresh controls and added/removed page diagnostics to the local library.
- Replace the truncated PNG directory fixture with a complete one while keeping strict
  rejection tests for bare signature and incomplete IHDR data.

## Unreleased — durable imported directory library

- Reject bare or truncated PNG container labels during Dart and Android directory sniffing.
- Persist imported folder chapters and per-page detected media formats in a local catalog.
- Add SQLite storage plus Flutter application-support path composition for the catalog.
- Restore the last Reader page and paged/continuous mode when reopening an imported chapter.
- Route reopened content URI and filesystem pages through LoaderTransport, DownloadSession,
  promoted artifacts, and the same Reader runtime as freshly imported folders.
- Clamp saved progress when a refreshed chapter loses pages, ignore stale progress writes,
  and cascade-delete progress when a chapter is removed.

## Unreleased — local-media boundary and Android folder import repair

- Move local image models, recursive filesystem scanning and format sniffing from the App
  package to `packages/local_media`.
- Keep Android SAF documents as MIME/name candidates when a header probe is unavailable,
  and read them through ordinary, asset or typed-asset content resolver streams.
- Add local-media bridge protocol version 2 to detect stale native plugin caches.
- Add `tool/clean.sh` for project-wide Flutter/Dart, Gradle, Rust, CMake and JNI cache cleanup.

# Changelog

- Reconcile two stale governance cross-references:024 no longer leaves accepted canonical099 open,and053 preserves accepted063/066/082 while retaining the original pressure batch037. Requirement IDs/statuses and production inputs are unchanged;stop completed scenarios instead of changing code from obsolete pending text.

- Fix compact Home focus leaking placeholder page URIs into version proof. Hydrate only compact focus through the existing library owner, recheck cancellation and stop when the real manifest is missing; preserve refreshed carriers and physical generations/prefixes. Three branches fail before the fix; four regressions pass including refreshed-carrier preservation. Fresh2368 tests/27 suites, analyzers, Rust22, repository/platform gates and three-ABI Debug/Profile/minifiedRelease/JNI pass. Ordinary Release499ee89d verifies actual EH371-to424 View and Reader80: canonical authority precedes acquisition,13,394,740 local bytes need no network admission, stationary image and zero failures. Close099 without reopening controlled acceptances; latest-update action remains023. Correct stale carrier-first wording in existing Spec/Architecture sections and strengthen the local gate; completed099 must leave the active Plan.

- Reconcile Venera cancellation acceptance with the current isolated rhttp executor instead of the retired native URLConnection/DNS-fallback implementation. Reuse hash-checked Network4/Cookie8 device evidence for held-body cancellation, complete bodies and header/Cookie semantics; retain real system-DNS cancellation and actual-origin latency as unverified. Preserve production inputs and frozen112 requirements while updating the four current state projections.
- Measure consecutive vertical drag velocity using increasing source input timestamps, so delayed then bunched callback delivery cannot distort input speed. Backdated source events continue publishing physical coverage while retaining the latest valid motion baseline; missing/equal timestamps keep callback fallback. Preserve ballistic, layout/phase and scroll-start/idle/controller retirement; directional failing-first regressions cover bursts, rewind and gesture reset. Temporary observation probes are removed (ADR0369 Provisional).

## Unreleased — source search input boundaries

- Release only the search input focus when its existing inset subtree observes the IME starting to hide. Preserve the panel for the following back event and keep catalog layout outside the keyboard dependency.
- Route ordinary history scroll notifications through the existing panel-collapse handler. Keep extended source/category option scrolling and its expansion handle available.
- Verify both failures before the fixes, the source-page suite (43 passed, 3 existing quarantines), and native Profile keyboard/back/history/catalog gestures on device. Six minified manifest stress runs also isolate an intermittent JM init HTTP deadline; all 30 recovery variants pass without changing the activation deadline or user settings.

## Unreleased fixed-overlay candidate from 0.18.3-dev.21

- Generalized directory import from extension-filtered WebP files to header-detected
  local images, including extensionless and incorrectly named image files.
- Added PNG/JPEG/GIF/WebP/BMP/TIFF/ICO/AVIF/HEIF signature recognition, stronger
  container-prefix checks, recursive natural sorting, and scan/unreadable diagnostics.
- Pinned the Android file-selector implementation that returns directory paths and
  rejects unexpected `content://` results as a path-capability error instead of an
  empty-image-folder result.
- Split Reader/folder smoke coverage from decoder completion: smoke tests assert
  component identity and explicit loading state, while preview tests own ready/invalid
  behavior. Preview observers now publish the current snapshot after first layout.
- Adopted the previous WebP-safe-folder candidate plus the exact five-file
  `fixed.zip` overlay as the sole continuing baseline.
- Preserved the overlay's partial-WebP decoder fixes while replacing fixed-duration
  widget synchronization with explicit preview-state observers and controlled futures.
- Replaced the Reader app's `FakeCoordinator` with `LiveCoordinator`, real transport
  selection, `DownloadRegistry`, and promoted-artifact media loading.
- Added observer-safe `DownloadSession` snapshots, cancellable WebP byte loads, and
  explicit Reader binding detach, preventing stale promotion listeners and demand
  plans during page replacement and teardown.
- Kept Reader WebP presentation on Flutter codec until Android native texture
  lifecycle/device validation succeeds.
- Retained recursive local-folder import, natural sorting, explicit relative
  display names and single-player switching, then generalized it to header-detected images.


## 0.18.3-dev.21

- Fixed the malformed-local-WebP smoke test by giving the primary validation message a stable `webpPreviewErrorKey`.
- Changed the secondary footer status from `WebP 文件无效` to `加载失败`, so product UI no longer exposes two matching validation messages.
- Replaced the global `find.textContaining` assertion with a keyed error-widget assertion and kept the exact imported filename check.
- Added repository regression gates that reject duplicate validation status text and unkeyed malformed-WebP assertions.
- Updated workspace/native versions to the 0.18.3 baseline.

## 0.18.2-dev.20

- Replaced the platform-dependent `Future<XFile?>` picker contract with `Future<PickedWebp?>`, which carries the selected file and an explicit normalized display name.
- Fixed local-import preview titles when `XFile.fromData` reports an empty `name` in Flutter tests; route titles now receive `local.webp` and `broken.webp` from the picker result rather than re-reading platform metadata.
- Added filename fallback from `XFile.name`, URI/path basename, and finally `本地 WebP` for real system-picker results.
- Kept the stable preview route/title keys and bounded route pumping from the previous repair, while adding repository gates for display-name ownership.
- Updated the native library version and its stale Rust assertion to the 0.18.2 baseline.

## 0.18.1-dev.19

- Fixed local WebP picker widget tests by waiting for a stable preview-route marker instead of assuming one timed pump completes asynchronous picker navigation and the route transition.
- Added stable preview screen/title keys shared by production code and widget tests.
- Kept malformed-file verification separate: tests first wait for the route, then wait for the controlled validation error.
- Added repository regression gates for preview route identity and asynchronous test synchronization.
- Added a next-chat handoff document for continuing from this exact baseline.

## 0.18.0-dev.18

- Fixed the local WebP picker smoke test to use a real finite-loop fixture and added a separate malformed-file regression with a controlled in-app error.
- Added `WebpInfo` parsing for VP8X, VP8, and VP8L containers so imported bytes are validated before either codec is created.
- Added `RasterPlan` to separate the adaptive physical display target from the encoded-image decode size.
- Stopped Flutter and native paths from upscaling tiny sources during decode; small partial-frame animations now compose at intrinsic size and use nearest-neighbour rendering.
- Kept large comic pages on aligned, DPR-aware downsample targets with smooth filtering and bounded pixel budgets.
- Avoided native cursor recreation when a viewport change alters only display scale but not the actual decode raster.
- Added pure-Dart raster/parser tests and a Flutter widget regression for the partial-blend fixture.

## 0.17.0-dev.17

- Fixed the missing `DecodeTarget` import in the static demo and moved the target model into its own pipeline module.
- Added viewport/DPR-aware physical decode targets with 8-pixel alignment, aspect-preserving fit, and a four-megapixel safety budget.
- Replaced the fixed 1024-pixel Animated WebP target; native and Flutter codec paths now share the same target derived from the actual image viewport.
- Fixed Flutter codec presentation by giving the image tight expanded constraints and matching `cacheWidth`/`cacheHeight` instead of rendering at intrinsic size.
- Changed native preview playback to prepare the next frame while the current frame is visible and subtract preparation time from the encoded duration, removing decode time from the animation timeline.
- Added pause-safe pending-frame/completion scheduling, physical-target tests, and frame-pacing regression tests.

## 0.16.0-dev.16

- Bundled the three deterministic Animated WebP fixtures as real Flutter app
  assets and added a checked JSON catalog.
- Replaced the automatic static-reader launch with a demo home that exposes the
  100-page chapter, bundled Animated WebP catalog, and local WebP import.
- Added system file selection through `file_selector` 1.0.3, selected to retain
  the workspace Dart 3.6 compatibility floor.
- Added an in-app Animated WebP player that can compare the native source/cursor
  pipeline with Flutter's codec and automatically falls back when the native
  runtime is unavailable or incorrectly linked.
- Added `PixelFrame`, raw RGBA-to-Flutter image presentation, alpha
  premultiplication, finite/infinite loop playback, pause/resume, and native
  runtime provenance reporting.
- Added fixture synchronization, asset/native-byte equality gates, app entry
  tests, catalog tests, and local-import route tests.

## 0.15.0-dev.15

- Replaced the external per-ABI `ZIC_ANDROID_WEBP_ROOT` contract with a pinned
  upstream libwebp source checkout.
- Added `native/libwebp.lock` for version 1.6.0 and exact commit verification
  against the official WebM repository.
- Added host and Android CMake source builders with isolated `.deps` build and
  install trees, Android NDK ABI configuration, and a static-by-default APK link.
- Updated Android native packaging to link only source-generated libraries and
  package upstream `COPYING`, `PATENTS`, and source provenance.
- Added source-built host smoke/Rust scripts and CI coverage for all Android
  ABIs; distribution `libwebp-dev` packages are no longer used by CI.
- Made native inclusion explicit with `ZIC_ANDROID_NATIVE`; split APK builds
  include the source-built media core by default and can opt out for UI-only CI.
- Bumped the native ABI to v5 and exposed linked libwebp decoder/demux versions
  so Dart can reject an incorrectly linked runtime instead of trusting filenames.

## 0.14.0-dev.14

- Replaced the nullable `FrameCursor.decodeNext()` result with explicit
  `CursorStep.frame`, `CursorStep.needMoreData`, and `CursorStep.end` states.
- Added `CursorBinding`, so `DecodeSession` receives frame and optional loop
  capabilities with static types and no `is LoopCursor` runtime branch.
- Updated native and fake cursor factories to return typed bindings; non-loop
  EOF now enters `DecodeState.ended` instead of being confused with incomplete
  input.
- Added media/session regressions for explicit cursor states and cancellation
  disposal.
- Hardened libwebp verification by checking every byte prefix of all animation
  fixtures and adding a bytewise native cursor test.
- Added Android Rust/libwebp per-ABI packaging scripts for arm64-v8a,
  armeabi-v7a, and x86_64, with shared/static dependency layouts.

## 0.13.0-dev.13

- Added native Animated WebP frame-count, play-count, metadata-complete, cycle,
  and rewind ABI functions.
- Added explicit infinite and finite animation loop semantics. Rewind is only
  accepted after end-of-stream and finite play counts are enforced natively.
- Added `AnimationInfo` and optional `LoopCursor` media contracts.
- Updated `DecodeSession` to rewind only after held frames are consumed and to
  enter an explicit `ended` state after a finite animation is exhausted.
- Added animation-loop telemetry, a finite-loop WebP fixture, C smoke coverage,
  Rust ownership/rewind tests, and Dart session-level loop tests.

## 0.12.0-dev.12

- Replaced the native WebP cursor placeholder with real incremental Animated
  WebP decoding through libwebp partial demux.
- Decode only complete frame fragments; incomplete prefixes return
  `needMoreData` without advancing cursor state.
- Added target-size RGBA composition with WebP blend and dispose handling,
  immutable frame handles, duration propagation, and one-pass end detection.
- Added a deterministic two-frame Animated WebP fixture and Rust tests for
  complete decode, partial-prefix waiting, frame bytes, and end-of-stream.
- Added system/custom libwebp link configuration, C dependency smoke checks,
  CI installation, and repository gates.

## 0.11.0-dev.11

- Made `ReaderBinding` require explicit `Coordinator` and
  `PlaybackCoordinator` dependencies instead of deriving playback capability
  from a demand coordinator at runtime.
- Added ABI v3 native cursor create/free/decode contracts with epoch checks and
  shared source ownership.
- Added retained native frame handles with immutable metadata/data access and
  independent retain/release lifetimes.
- Added Dart `NativeCursorFactory`, `NativeCursor`, and `NativeFrame` wrappers.
- Added `SourceStatus.failed` and source-lock failure handling.
- Added reader-binding interface separation, ABI enum/version, source/cursor
  ownership, and frame-retain regression tests.

## 0.10.0-dev.10

- Replaced the stale `ReadingDirection.leftToRight` test value with `ltr`.
- Added `ReaderBinding` to drive demand reconciliation and viewport playback
  from the same reader observation, and connected the demo app to the binding.
- Added decoded-frame and renderer-output byte budgets with current-page
  reserves and low-priority non-current trimming.
- Added output byte accounting, claim-safe frame/output trimming, and frame
  budget telemetry in `LiveCoordinator`.
- Added reader-binding and frame-budget integration tests plus regression gates.

## 0.9.0-dev.9

- Removed invalid trailing commas from native source enum index expressions.
- Added split-per-ABI Android APK builds through `tool/build_android.sh`.
- Switched CI and full toolchain checks from fat APK to split APK output.
- Added viewport idle/dominant/overlap/continuous phase resolution.
- Added playback gating and coordinator integration for viewport freeze/resume.
- Added regression tests for discrete overlap, target dominance, continuous
  scrolling, and playback-gate state transitions.

## 0.8.0-dev.8

- Fixed duplicate upload work caused by source-ready and download-complete wake-ups.
- Counted renderer-owned ready output toward the decode watermark.
- Added non-cancelling lane follow-up work with per-key coalescing.
- Added explicit frame advancement; source progress alone no longer advances playback.
- Added a playback timer whose duration starts after actual present, with freeze/resume.
- Added regressions for duplicate upload, prepared depth, lane follow-up, and playback timing.

## 0.7.0-dev.7

- Imported `EncodedSource` in the frame cursor contract.
- Fixed `Artifact.readPrefix()` closing its random-access file before the
  asynchronous read completed.
- Added an immediate prefix-read/file-close regression test.
- Added renderer-owned output frame and frame uploader contracts.
- Added upload sessions and registry with upload and present claims.
- Deferred output disposal while a present claim remains active.
- Rejected and disposed stale upload results.
- Connected successful decode work to upload-demand wake-up.
- Added upload state, uploaded-frame, and presented-frame telemetry.

## 0.6.0-dev.6

- Fixed restored sniff prefixes being stored as unmodifiable lists.
- Changed artifacts to open partial writers lazily and serialize writes.
- Removed idle file handles from startup recovery and cache scanning.
- Added source-ready/source-disabled telemetry and early decode wake-up.
- Added frame/cursor contracts, frame holder claims, decode sessions, and a
  decode registry keyed by `DecodeId` and source epoch.
- Made coordinator idle detection stable across work submitted by other lanes.
- Added regression coverage for the reported session failures and decode flow.
- Copied queued byte chunks at ownership boundaries and isolated
  source-listener failures.
- Disposed frames decoded after cancellation or epoch supersession.
- Fixed coordinator upload dispatch and cancellation of detached active
  downloads during dispose.

## 0.5.0-dev.5

- Fixed the missing `DownloadSession` import in `LiveCoordinator`.
- Moved `RetryPolicy` duration validation out of const evaluation.
- Added the pure Dart media contracts, source pool, and format-aware ingress.
- Mirrored confirmed WebP downloads into native encoded sources while keeping
  artifacts authoritative.
- Rebuild encoded sources from restored partial/final artifacts.
- Added ingress and download-integration regression tests.

## 0.4.0-dev.4

- Fixed Flutter platform-generation and test working directories.
- Added explicit Flutter and Dart package test runners.
- Added cache limits, LRU planning, safe trim/clear, and released-byte reports.
- Added bounded retry/backoff for demanded failed downloads.
- Added decode, upload, and maintenance lane shells.
- Added Rust incremental byte-source ABI and Dart FFI wrapper.

## 0.3.0-dev.3

- Renamed the reserved `library` package to `catalog`.
- Added cache index, scanner, startup recovery, network lane, and live download
  coordination.
