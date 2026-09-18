import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/src/external_plugin_mutation_gate.dart';

void main() {
  test('close rejects new durable mutations and waits admitted work', () async {
    final gate = ExternalPluginMutationGate();
    final release = Completer<void>();
    final started = Completer<void>();
    final mutation = gate.run<void>('fixture', () async {
      started.complete();
      await release.future;
    });
    await started.future;

    var drained = false;
    final close = gate.beginClose().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(
      gate.run<void>('fixture', () async {}),
      throwsA(isA<StateError>()),
    );

    release.complete();
    await mutation;
    await close;
    expect(drained, isTrue);
  });

  test('same-plugin durable mutations run in admission order', () async {
    final gate = ExternalPluginMutationGate();
    final firstRelease = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();

    final first = gate.run<void>('same-plugin', () async {
      firstStarted.complete();
      await firstRelease.future;
    });
    await firstStarted.future;
    final second = gate.run<void>('same-plugin', () async {
      secondStarted.complete();
    });

    await Future<void>.delayed(Duration.zero);
    expect(secondStarted.isCompleted, isFalse);

    firstRelease.complete();
    await first;
    await secondStarted.future;
    await second;
  });

  test('different plugin durable mutations remain concurrent', () async {
    final gate = ExternalPluginMutationGate();
    final release = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();

    final first = gate.run<void>('first-plugin', () async {
      firstStarted.complete();
      await release.future;
    });
    final second = gate.run<void>('second-plugin', () async {
      secondStarted.complete();
      await release.future;
    });

    await Future.wait<void>(
      <Future<void>>[firstStarted.future, secondStarted.future],
    );
    release.complete();
    await Future.wait<void>(<Future<void>>[first, second]);
  });

  test('failed admitted mutation still releases close drain', () async {
    final gate = ExternalPluginMutationGate();
    final release = Completer<void>();
    final started = Completer<void>();
    final mutation = gate.run<void>('fixture', () async {
      started.complete();
      await release.future;
      throw StateError('mutation failed');
    });
    await started.future;

    final close = gate.beginClose();
    release.complete();
    await expectLater(mutation, throwsA(isA<StateError>()));
    await close;
  });
}
