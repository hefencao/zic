import 'dart:async';

import 'package:sessions/sessions.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';

void main() {
  _dev123NetLaneTests();
  test('queues by priority and keeps FIFO for equal priorities', () async {
    final lane = NetLane(maxActive: 1);
    final gate = Completer<void>();
    final order = <String>[];

    lane.submit(
      key: 'running',
      priority: 1,
      task: (_) async => gate.future,
    );
    lane.submit(
      key: 'low',
      priority: 10,
      task: (_) async => order.add('low'),
    );
    lane.submit(
      key: 'high-a',
      priority: 20,
      task: (_) async => order.add('high-a'),
    );
    lane.submit(
      key: 'high-b',
      priority: 20,
      task: (_) async => order.add('high-b'),
    );

    gate.complete();
    await lane.idle();
    expect(order, <String>['high-a', 'high-b', 'low']);
  });

  test('coalesces and cancels queued work by key', () async {
    final lane = NetLane(maxActive: 1);
    final gate = Completer<void>();
    final values = <int>[];

    lane.submit(key: 'running', priority: 1, task: (_) async => gate.future);
    lane.submit(key: 'same', priority: 1, task: (_) async => values.add(1));
    lane.submit(key: 'same', priority: 2, task: (_) async => values.add(2));
    expect(lane.cancelQueued('same'), isTrue);

    gate.complete();
    await lane.idle();
    expect(values, isEmpty);
  });
  test('replace cancels active work and runs the replacement next', () async {
    final lane = DecodeLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    final values = <String>[];

    lane.submit(
      key: 'same',
      priority: 1,
      task: (token) async {
        values.add('old');
        started.complete();
        await Future.any<void>(<Future<void>>[
          release.future,
          token.whenCancelled,
        ]);
      },
    );
    await started.future;
    lane.replace(
      key: 'same',
      priority: 2,
      task: (token) async {
        expect(token.flowTargetFrames, 0);
        values.add('new');
      },
    );

    release.complete();
    await lane.idle();
    expect(values, <String>['old', 'new']);
  });


  test('follow queues one successor without cancelling active work', () async {
    final lane = UploadLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    final values = <String>[];

    lane.submit(
      key: 'same',
      priority: 1,
      task: (token) async {
        values.add('active');
        started.complete();
        await release.future;
        expect(token.cancelled, isFalse);
      },
    );
    await started.future;
    lane.follow(
      key: 'same',
      priority: 2,
      task: (_) async => values.add('old-follow'),
    );
    lane.follow(
      key: 'same',
      priority: 3,
      task: (token) async {
        expect(token.flowTargetFrames, 0);
        values.add('latest-follow');
      },
    );

    release.complete();
    await lane.idle();
    expect(values, <String>['active', 'latest-follow']);
  });

  test('decode lane reserves one handoff for current and preempts lower work', () async {
    final lane = DecodeLane(
      maxActive: 3,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
    );
    final started = <String>[];
    final release = <String, Completer<void>>{
      for (var i = 0; i < 3; i++) 'prefetch-$i': Completer<void>(),
    };
    final cancelled = Completer<String>();

    for (var i = 0; i < 3; i++) {
      final key = 'prefetch-$i';
      lane.submit(
        key: key,
        priority: 700 + i * 10,
        task: (token) async {
          started.add(key);
          await Future.any<void>(<Future<void>>[
            release[key]!.future,
            token.whenCancelled.then((_) {
              if (!cancelled.isCompleted) cancelled.complete(key);
            }),
          ]);
        },
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 3);

    final currentStarted = Completer<void>();
    lane.submit(
      key: 'current',
      priority: 1000,
      task: (_) async {
        started.add('current');
        currentStarted.complete();
      },
    );

    await currentStarted.future;
    expect(await cancelled.future, 'prefetch-0');
    expect(started, contains('current'));
    for (final gate in release.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await lane.idle();
  });

  test('upload lane keeps reserved handoff exclusive to current priority', () async {
    final lane = UploadLane(
      maxActive: 2,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
    );
    final releases = <Completer<void>>[Completer<void>(), Completer<void>()];
    for (var i = 0; i < releases.length; i++) {
      lane.submit(
        key: 'prefetch-$i',
        priority: 700 + i * 10,
        task: (token) => Future.any<void>(<Future<void>>[
          releases[i].future,
          token.whenCancelled,
        ]),
      );
    }
    await Future<void>.delayed(Duration.zero);

    var transitionStarted = false;
    lane.submit(
      key: 'transition',
      priority: 900,
      task: (_) async => transitionStarted = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(transitionStarted, isFalse,
        reason: 'Vibe-style reserved execution slot belongs to current, not transition prefetch');

    final currentStarted = Completer<void>();
    lane.submit(
      key: 'current',
      priority: 1000,
      task: (_) async => currentStarted.complete(),
    );
    await currentStarted.future;

    for (final gate in releases) {
      if (!gate.isCompleted) gate.complete();
    }
    await lane.idle();
    expect(transitionStarted, isTrue);
  });

  test('cancelAll clears pending work and signals active tokens', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<void>();
    final activeCancelled = Completer<void>();
    var queuedRan = false;

    lane.submit(
      key: 'active',
      priority: 1,
      task: (token) async {
        started.complete();
        await token.whenCancelled;
        activeCancelled.complete();
      },
    );
    lane.submit(
      key: 'queued',
      priority: 2,
      task: (_) async {
        queuedRan = true;
      },
    );
    await started.future;

    lane.cancelAll();
    await activeCancelled.future;
    await lane.idle();

    expect(queuedRan, isFalse);
    expect(lane.queued, 0);
    expect(lane.active, 0);
  });

  test('ranked page work enforces global and per-source limits', () async {
    final lane = NetLane(maxActive: 5);
    final release = Completer<void>();
    final started = <String>[];

    for (var index = 0; index < 6; index++) {
      lane.submitRanked(
        key: 'remote-a-$index',
        priority: 800 - index,
        bucket: 'remote:a',
        bucketLimit: 3,
        task: (_) async {
          started.add('a$index');
          await release.future;
        },
      );
    }
    for (var index = 0; index < 4; index++) {
      lane.submitRanked(
        key: 'remote-b-$index',
        priority: 700 - index,
        bucket: 'remote:b',
        bucketLimit: 5,
        task: (_) async {
          started.add('b$index');
          await release.future;
        },
      );
    }

    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 5);
    expect(started.where((value) => value.startsWith('a')), hasLength(3));
    expect(started.where((value) => value.startsWith('b')), hasLength(2));

    release.complete();
    await lane.idle();
  });

  test('idleKeys ignores work owned by another Reader', () async {
    final lane = NetLane(maxActive: 2);
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();

    lane.submitRanked(
      key: 'reader-1:page',
      priority: 1000,
      bucket: 'local',
      bucketLimit: 5,
      task: (_) async => firstRelease.future,
    );
    lane.submitRanked(
      key: 'reader-2:page',
      priority: 1000,
      bucket: 'local',
      bucketLimit: 5,
      task: (_) async => secondRelease.future,
    );

    final firstIdle = lane.idleKeys(<String>['reader-1:page']);
    lane.cancel('reader-1:page');
    firstRelease.complete();
    await firstIdle;
    expect(lane.active, 1);

    secondRelease.complete();
    await lane.idle();
  });




}

// dev.123 current-page migration/preemption contracts.
void _dev123NetLaneTests() {
  test('active same-key promotion updates rank without restarting transfer', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    var runs = 0;

    lane.submitRanked(
      key: 'page',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        runs++;
        started.complete();
        await release.future;
      },
    );
    await started.future;

    expect(
      lane.submitRanked(
        key: 'page',
        priority: 1000,
        bucket: 'remote:a',
        bucketLimit: 5,
        task: (_) async => runs++,
      ),
      isFalse,
    );
    expect(lane.priorityOf('page'), 1000);
    expect(runs, 1);

    release.complete();
    await lane.idle();
    expect(runs, 1);
  });

  test('active rank migration emits the scheduler-owned priority signal', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<void>();
    final observed = Completer<int>();
    final release = Completer<void>();

    lane.submitRanked(
      key: 'page-signal',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (token) async {
        token.priorityChanges.listen((priority) {
          if (!observed.isCompleted) observed.complete(priority);
        });
        started.complete();
        await release.future;
      },
    );
    await started.future;

    expect(
      lane.submitRanked(
        key: 'page-signal',
        priority: 1000,
        bucket: 'remote:a',
        bucketLimit: 5,
        task: (_) async {},
      ),
      isFalse,
    );
    expect(await observed.future, 1000);
    expect(lane.priorityOf('page-signal'), 1000);

    release.complete();
    await lane.idle();
  });

  test('current borrows one handoff slot without cancelling active transfers',
      () async {
    final lane = NetLane(maxActive: 2, reservedHighPrioritySlots: 1);
    final lowCancelled = Completer<void>();
    final lowRelease = Completer<void>();
    final mediumRelease = Completer<void>();
    final currentStarted = Completer<void>();
    final currentRelease = Completer<void>();

    lane.submitRanked(
      key: 'low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await Future.any<void>(<Future<void>>[
          token.whenCancelled,
          lowRelease.future,
        ]);
        if (token.cancelled) lowCancelled.complete();
      },
    );
    lane.submitRanked(
      key: 'medium',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async => mediumRelease.future,
    );
    await Future<void>.delayed(Duration.zero);

    lane.submitRanked(
      key: 'current',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentStarted.complete();
        await currentRelease.future;
      },
    );

    await currentStarted.future;
    expect(lane.active, 3);
    expect(lane.handoffActive, 1);
    expect(lowCancelled.isCompleted, isFalse);

    currentRelease.complete();
    lowRelease.complete();
    mediumRelease.complete();
    await lane.idle();
  });

  test('current borrows source bucket headroom before cancelling a transfer',
      () async {
    final lane = NetLane(maxActive: 5, reservedHighPrioritySlots: 1);
    final firstCancelled = Completer<void>();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    final currentStarted = Completer<void>();
    final currentRelease = Completer<void>();

    lane.submitRanked(
      key: 'bucket-low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await Future.any<void>(<Future<void>>[
          token.whenCancelled,
          firstRelease.future,
        ]);
        if (token.cancelled) firstCancelled.complete();
      },
    );
    lane.submitRanked(
      key: 'bucket-near',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async => secondRelease.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 2);

    lane.submitRanked(
      key: 'bucket-current',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentStarted.complete();
        await currentRelease.future;
      },
    );

    await currentStarted.future;
    expect(lane.active, 3);
    expect(lane.activeForBucket('remote:a'), 3);
    expect(lane.handoffActive, 1);
    expect(firstCancelled.isCompleted, isFalse);

    currentRelease.complete();
    firstRelease.complete();
    secondRelease.complete();
    await lane.idle();
  });

  test(
      'blocked current preempts only after reserved headroom is occupied',
      () async {
    final lane = NetLane(
      maxActive: 5,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
    );
    final lowestCancelled = Completer<void>();
    final otherRelease = Completer<void>();
    final firstCurrentStarted = Completer<void>();
    final firstCurrentRelease = Completer<void>();
    final secondCurrentStarted = Completer<void>();

    lane.submitRanked(
      key: 'prefetch-0',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (token) async {
        await token.whenCancelled;
        lowestCancelled.complete();
      },
    );
    for (var index = 1; index < 5; index++) {
      lane.submitRanked(
        key: 'prefetch-$index',
        priority: 680 + index * 20,
        bucket: 'remote:a',
        bucketLimit: 5,
        task: (_) async => otherRelease.future,
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 5);

    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        firstCurrentStarted.complete();
        await firstCurrentRelease.future;
      },
    );
    await firstCurrentStarted.future;
    expect(lane.active, 6);
    expect(lane.handoffActive, 1);
    expect(lowestCancelled.isCompleted, isFalse);

    lane.submitRanked(
      key: 'current-b',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        secondCurrentStarted.complete();
      },
    );

    await lowestCancelled.future.timeout(const Duration(seconds: 1));
    await secondCurrentStarted.future.timeout(const Duration(seconds: 1));
    expect(firstCurrentRelease.isCompleted, isFalse);

    firstCurrentRelease.complete();
    otherRelease.complete();
    await lane.idle();
  });

  test(
      'transient blocked current does not destructively preempt before candidate grace',
      () async {
    final lane = NetLane(
      maxActive: 1,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      preemptionCandidateGrace: const Duration(milliseconds: 30),
    );
    final retainedCancelled = Completer<void>();
    final retainedRelease = Completer<void>();
    final firstCurrentStarted = Completer<void>();
    final firstCurrentRelease = Completer<void>();
    final transientStarted = Completer<void>();

    lane.submitRanked(
      key: 'retained',
      priority: 0,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        await Future.any<void>(<Future<void>>[
          token.whenCancelled,
          retainedRelease.future,
        ]);
        if (token.cancelled) retainedCancelled.complete();
      },
    );
    await Future<void>.delayed(Duration.zero);

    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async {
        firstCurrentStarted.complete();
        await firstCurrentRelease.future;
      },
    );
    await firstCurrentStarted.future;
    expect(lane.active, 2);
    expect(lane.handoffActive, 1);

    lane.submitRanked(
      key: 'transient-current',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async => transientStarted.complete(),
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(retainedCancelled.isCompleted, isFalse);
    expect(transientStarted.isCompleted, isFalse);

    expect(lane.updatePriority('transient-current', 820), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(retainedCancelled.isCompleted, isFalse);
    expect(transientStarted.isCompleted, isFalse);

    firstCurrentRelease.complete();
    retainedRelease.complete();
    await lane.idle();
  });

  test('stable blocked current preempts after candidate grace', () async {
    final lane = NetLane(
      maxActive: 1,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      preemptionCandidateGrace: const Duration(milliseconds: 30),
    );
    final retainedCancelled = Completer<void>();
    final firstCurrentStarted = Completer<void>();
    final firstCurrentRelease = Completer<void>();
    final secondCurrentStarted = Completer<void>();

    lane.submitRanked(
      key: 'retained',
      priority: 0,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        await token.whenCancelled;
        retainedCancelled.complete();
      },
    );
    await Future<void>.delayed(Duration.zero);

    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async {
        firstCurrentStarted.complete();
        await firstCurrentRelease.future;
      },
    );
    await firstCurrentStarted.future;

    lane.submitRanked(
      key: 'current-b',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async => secondCurrentStarted.complete(),
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(retainedCancelled.isCompleted, isFalse);
    expect(secondCurrentStarted.isCompleted, isFalse);

    await retainedCancelled.future.timeout(const Duration(seconds: 1));
    await secondCurrentStarted.future.timeout(const Duration(seconds: 1));

    firstCurrentRelease.complete();
    await lane.idle();
  });

  test('only one destructive preemption may be in flight', () async {
    final lane = NetLane(
      maxActive: 2,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
    );
    final firstCancelled = Completer<void>();
    final firstExit = Completer<void>();
    final secondCancelled = Completer<void>();
    final secondExit = Completer<void>();
    final currentAStarted = Completer<void>();
    final currentARelease = Completer<void>();
    final currentBStarted = Completer<void>();
    final currentBRelease = Completer<void>();

    lane.submitRanked(
      key: 'low-a',
      priority: 0,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await token.whenCancelled;
        firstCancelled.complete();
        await firstExit.future;
      },
    );
    lane.submitRanked(
      key: 'low-b',
      priority: 0,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        await token.whenCancelled;
        secondCancelled.complete();
        await secondExit.future;
      },
    );
    await Future<void>.delayed(Duration.zero);

    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentAStarted.complete();
        await currentARelease.future;
      },
    );
    await firstCancelled.future.timeout(const Duration(seconds: 1));

    lane.submitRanked(
      key: 'current-b',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        currentBStarted.complete();
        await currentBRelease.future;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(secondCancelled.isCompleted, isFalse);
    expect(currentBStarted.isCompleted, isFalse);

    firstExit.complete();
    await currentAStarted.future.timeout(const Duration(seconds: 1));
    await secondCancelled.future.timeout(const Duration(seconds: 1));
    secondExit.complete();
    await currentBStarted.future.timeout(const Duration(seconds: 1));
    currentARelease.complete();
    currentBRelease.complete();
    await lane.idle();
  });

  test(
      'previous waits for a normal slot without cancelling retained receiving',
      () async {
    final lane = NetLane(
      maxActive: 3,
      reservedHighPrioritySlots: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
    );
    final lowestCancelled = Completer<void>();
    final lowestRelease = Completer<void>();
    final secondLowRelease = Completer<void>();
    final otherRelease = Completer<void>();
    final previousStarted = Completer<void>();
    final previousRelease = Completer<void>();

    lane.submitRanked(
      key: 'low-prefetch-720',
      priority: 720,
      bucket: 'remote:a',
      bucketLimit: 3,
      task: (token) async {
        await Future.any<void>(<Future<void>>[
          token.whenCancelled,
          lowestRelease.future,
        ]);
        if (token.cancelled) lowestCancelled.complete();
      },
    );
    lane.submitRanked(
      key: 'low-prefetch-740',
      priority: 740,
      bucket: 'remote:a',
      bucketLimit: 3,
      task: (_) async => secondLowRelease.future,
    );
    lane.submitRanked(
      key: 'near-work',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 3,
      task: (_) async => otherRelease.future,
    );
    await Future<void>.delayed(Duration.zero);
    expect(lane.active, 3);

    lane.submitRanked(
      key: 'adjacent-previous',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 3,
      task: (_) async {
        previousStarted.complete();
        await previousRelease.future;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(lowestCancelled.isCompleted, isFalse);
    expect(previousStarted.isCompleted, isFalse);
    expect(lane.active, 3);
    expect(lane.handoffActive, 0);

    lowestRelease.complete();
    await previousStarted.future.timeout(const Duration(seconds: 1));
    expect(lowestCancelled.isCompleted, isFalse);
    expect(lane.active, 3);
    expect(lane.handoffActive, 0);

    previousRelease.complete();
    secondLowRelease.complete();
    otherRelease.complete();
    await lane.idle();
  });


  test('restart-cost retention changes victim choice but not admission rank',
      () async {
    final clock = FakeMonoClock();
    final lane = NetLane(
      maxActive: 2,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      clock: clock,
    );
    late CancelToken investedToken;
    late CancelToken cheapToken;
    final investedRelease = Completer<void>();
    final cheapCancelled = Completer<void>();
    final incomingStarted = Completer<void>();

    lane.submitRanked(
      key: 'invested-780',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        investedToken = token;
        token.beginRestartCost();
        token.recordRestartCostBytes(8 * 1024 * 1024);
        await Future.any<void>(<Future<void>>[
          token.whenCancelled,
          investedRelease.future,
        ]);
      },
    );
    lane.submitRanked(
      key: 'cheap-800',
      priority: 800,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (token) async {
        cheapToken = token;
        await token.whenCancelled;
        cheapCancelled.complete();
      },
    );
    await Future<void>.delayed(Duration.zero);
    clock.advance(const Duration(seconds: 10));

    expect(lane.priorityOf('invested-780'), 780);
    expect(investedToken.restartCostBytes, 8 * 1024 * 1024);

    lane.submitRanked(
      key: 'current-1000-victim-choice',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 2,
      task: (_) async {
        incomingStarted.complete();
      },
    );

    await cheapCancelled.future.timeout(const Duration(seconds: 1));
    await incomingStarted.future.timeout(const Duration(seconds: 1));
    expect(investedToken.cancelled, isFalse);
    expect(cheapToken.preemptionSnapshot?.retentionBonus, 0);
    expect(cheapToken.preemptionSnapshot?.incomingPriority, 1000);

    investedRelease.complete();
    await lane.idle();
  });

  test('provider decisions reuse the scheduler restart-cost policy rank',
      () async {
    final clock = FakeMonoClock();
    final lane = NetLane(
      maxActive: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      clock: clock,
    );
    late CancelToken token;
    final release = Completer<void>();

    lane.submitRanked(
      key: 'provider-rank',
      priority: 820,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (activeToken) async {
        token = activeToken;
        await release.future;
      },
    );
    await Future<void>.delayed(Duration.zero);

    final initial = lane.activePolicyRank(
      'provider-rank',
      basePriority: 820,
    )!;
    expect(initial.effectivePriority, 820);
    expect(lane.incomingOutranks(850, initial), isFalse);
    expect(lane.incomingOutranks(860, initial), isTrue);

    token.beginRestartCost();
    token.recordRestartCostBytes(64 * 1024 * 1024);
    clock.advance(const Duration(minutes: 2));
    final invested = lane.activePolicyRank(
      'provider-rank',
      basePriority: 820,
    )!;
    expect(invested.effectivePriority, greaterThan(820));
    expect(lane.incomingOutranks(900, invested), isFalse);
    expect(lane.incomingOutranks(1000, invested), isTrue);

    release.complete();
    await lane.idle();
  });

  test('current preempts even a saturated restart-cost victim', () async {
    final clock = FakeMonoClock();
    final lane = NetLane(
      maxActive: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      clock: clock,
    );
    late CancelToken investedToken;
    final investedCancelled = Completer<void>();
    final currentStarted = Completer<void>();

    lane.submitRanked(
      key: 'invested-780',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        investedToken = token;
        token.beginRestartCost();
        token.recordRestartCostBytes(64 * 1024 * 1024);
        await token.whenCancelled;
        investedCancelled.complete();
      },
    );
    await Future<void>.delayed(Duration.zero);
    clock.advance(const Duration(minutes: 2));

    expect(lane.priorityOf('invested-780'), 780);

    lane.submitRanked(
      key: 'current-1000',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async {
        currentStarted.complete();
      },
    );

    await investedCancelled.future.timeout(const Duration(seconds: 1));
    await currentStarted.future.timeout(const Duration(seconds: 1));
    expect(investedToken.preemptionSnapshot?.retentionPriority, 933);
    expect(investedToken.preemptionSnapshot?.retentionBonus, 153);
    await lane.idle();
  });

  test('partial headroom keeps detached restart cost meaningful without blocking current', () async {
    final clock = FakeMonoClock();
    final lane = NetLane(
      maxActive: 1,
      highPriorityThreshold: 1000,
      preemptionThreshold: 40,
      clock: clock,
    );
    late CancelToken investedToken;
    final investedCancelled = Completer<void>();
    final currentStarted = Completer<void>();

    lane.submitRanked(
      key: 'detached-invested',
      priority: 0,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        investedToken = token;
        token.beginRestartCost();
        token.recordRestartCostBytes(64 * 1024 * 1024);
        await token.whenCancelled;
        investedCancelled.complete();
      },
    );
    await Future<void>.delayed(Duration.zero);
    clock.advance(const Duration(minutes: 2));

    lane.submitRanked(
      key: 'current-1000-after-detach',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async { currentStarted.complete(); },
    );

    await investedCancelled.future.timeout(const Duration(seconds: 1));
    await currentStarted.future.timeout(const Duration(seconds: 1));
    expect(investedToken.preemptionSnapshot?.basePriority, 0);
    expect(investedToken.preemptionSnapshot?.retentionPriority, 673);
    expect(investedToken.preemptionSnapshot?.retentionBonus, 673);
    await lane.idle();
  });

  test('handoff capacity stays bounded while cancellation unwinds', () async {
    final lane = NetLane(maxActive: 1, reservedHighPrioritySlots: 1);
    final lowRelease = Completer<void>();
    final firstCurrentStarted = Completer<void>();
    final firstCurrentRelease = Completer<void>();
    var secondCurrentStarted = false;

    lane.submitRanked(
      key: 'low',
      priority: 680,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async => lowRelease.future,
    );
    await Future<void>.delayed(Duration.zero);
    lane.submitRanked(
      key: 'current-a',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        firstCurrentStarted.complete();
        await firstCurrentRelease.future;
      },
    );
    await firstCurrentStarted.future;
    lane.submitRanked(
      key: 'current-b',
      priority: 1000,
      bucket: 'remote:a',
      bucketLimit: 5,
      task: (_) async {
        secondCurrentStarted = true;
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(lane.active, 2);
    expect(secondCurrentStarted, isFalse);

    lowRelease.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(secondCurrentStarted, isTrue);

    firstCurrentRelease.complete();
    await lane.idle();
  });

  test('flow target updates reach the same active token without resubmission', () async {
    final lane = NetLane(maxActive: 1);
    final started = Completer<CancelToken>();
    final release = Completer<void>();

    lane.submitRanked(
      key: 'animated',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 1,
      flowTargetFrames: 1,
      task: (token) async {
        started.complete(token);
        await release.future;
      },
    );
    final token = await started.future;
    expect(token.flowTargetFrames, 1);

    expect(lane.updateFlowTargetFrames('animated', 5), isTrue);
    expect(token.flowTargetFrames, 5);
    expect(lane.active, 1);

    expect(lane.updateFlowTargetFrames('animated', 0), isTrue);
    expect(token.flowTargetFrames, 0);
    expect(lane.active, 1);

    release.complete();
    await lane.idle();
  });

  test('flow target can change while queued without changing admission rank', () async {
    final lane = NetLane(maxActive: 1);
    final blocker = Completer<void>();
    final started = Completer<CancelToken>();

    lane.submitRanked(
      key: 'blocker',
      priority: 900,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) => blocker.future,
    );
    lane.submitRanked(
      key: 'animated',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 1,
      flowTargetFrames: 1,
      task: (token) async => started.complete(token),
    );
    expect(lane.updateFlowTargetFrames('animated', 3), isTrue);
    expect(lane.priorityOf('animated'), 780);

    blocker.complete();
    final token = await started.future;
    expect(token.flowTargetFrames, 3);
    await lane.idle();
  });

  test('normal pressure never reclaims an active task that still has demand', () async {
    final lane = NetLane(maxActive: 1);
    final incumbentStarted = Completer<CancelToken>();
    final incumbentRelease = Completer<void>();
    var incomingStarted = false;

    lane.submitRanked(
      key: 'incumbent-demanded',
      priority: 0,
      demanded: true,
      task: (token) async {
        incumbentStarted.complete(token);
        await incumbentRelease.future;
      },
    );
    final incumbent = await incumbentStarted.future;
    lane.submitRanked(
      key: 'incoming-normal',
      priority: 780,
      demanded: true,
      task: (_) async {
        incomingStarted = true;
      },
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(incumbent.cancelled, isFalse);
    expect(lane.demandedOf('incumbent-demanded'), isTrue);
    expect(incomingStarted, isFalse);

    incumbentRelease.complete();
    await lane.idle();
    expect(incomingStarted, isTrue);
  });

  test('parked response releases read permit without cancelling physical task',
      () async {
    final lane = NetLane(maxActive: 1, maxParkedResponses: 2);
    final firstStarted = Completer<CancelToken>();
    final firstRelease = Completer<void>();
    final secondStarted = Completer<void>();
    final secondRelease = Completer<void>();

    lane.submitRanked(
      key: 'first',
      priority: 800,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        firstStarted.complete(token);
        await Future.any<void>(<Future<void>>[
          firstRelease.future,
          token.whenCancelled,
        ]);
      },
    );
    final first = await firstStarted.future;
    first.releaseResponseReadPermit();
    await Future<void>.delayed(Duration.zero);
    expect(first.cancelled, isFalse);
    expect(lane.active, 0);
    expect(lane.running, 1);
    expect(lane.parkedResponses, 1);
    expect(lane.responseReadPermitHeldOf('first'), isFalse);

    lane.submitRanked(
      key: 'second',
      priority: 780,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async {
        secondStarted.complete();
        await secondRelease.future;
      },
    );
    await secondStarted.future;
    expect(lane.active, 1);
    expect(lane.running, 2);

    var resumed = false;
    final reacquire = first.acquireResponseReadPermit().then((_) {
      resumed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(resumed, isFalse);
    expect(first.cancelled, isFalse);

    secondRelease.complete();
    await reacquire.timeout(const Duration(seconds: 1));
    expect(first.cancelled, isFalse);
    expect(lane.active, 1);
    expect(lane.responseReadPermitHeldOf('first'), isTrue);

    firstRelease.complete();
    await lane.idle();
  });

  test('parked response pool evicts explicitly only after its bound is exceeded',
      () async {
    final lane = NetLane(maxActive: 1, maxParkedResponses: 1);
    final firstStarted = Completer<CancelToken>();
    final secondStarted = Completer<CancelToken>();

    lane.submitRanked(
      key: 'first-parked',
      priority: 700,
      demanded: false,
      task: (token) async {
        firstStarted.complete(token);
        await token.whenCancelled;
      },
    );
    // demanded=false pending is not admitted; attach, start, then detach.
    lane.updateDemanded('first-parked', true);
    final first = await firstStarted.future;
    lane.updateDemanded('first-parked', false);
    first.releaseResponseReadPermit();

    lane.submitRanked(
      key: 'second-parked',
      priority: 800,
      task: (token) async {
        secondStarted.complete(token);
        await token.whenCancelled;
      },
    );
    final second = await secondStarted.future;
    second.releaseResponseReadPermit();

    await first.whenCancelled.timeout(const Duration(seconds: 1));
    expect(first.preemptionSnapshot?.reason, 'parked-response-eviction');
    expect(second.cancelled, isFalse);
    expect(lane.parkedResponses, lessThanOrEqualTo(1));

    second.cancel();
    await lane.idle();
  });

  test('reattaching demand keeps the same admitted task identity', () async {
    final lane = NetLane(maxActive: 1);
    final incumbentStarted = Completer<CancelToken>();
    final incumbentRelease = Completer<void>();
    var incomingStarted = false;

    lane.submitRanked(
      key: 'revisited',
      priority: 820,
      task: (token) async {
        incumbentStarted.complete(token);
        await incumbentRelease.future;
      },
    );
    final incumbent = await incumbentStarted.future;
    lane.updatePriority('revisited', 0);
    lane.updateDemanded('revisited', false);

    // A quick turn back reuses the same physical task identity instead of
    // cancelling/reopening it.
    lane.updateDemanded('revisited', true);
    lane.updatePriority('revisited', 800);
    expect(lane.demandedOf('revisited'), isTrue);

    lane.submitRanked(
      key: 'outer-normal',
      priority: 780,
      task: (_) async {
        incomingStarted = true;
      },
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(incumbent.cancelled, isFalse);
    expect(incomingStarted, isFalse);

    incumbentRelease.complete();
    await lane.idle();
    expect(incomingStarted, isTrue);
  });

}
