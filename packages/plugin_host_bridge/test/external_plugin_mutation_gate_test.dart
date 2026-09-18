import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/src/external_plugin_mutation_gate.dart';

void main() {
  test('close rejects new durable mutations and waits admitted work', () async {
    final gate = ExternalPluginMutationGate();
    final release = Completer<void>();
    final started = Completer<void>();
    final mutation = gate.run<void>(() async {
      started.complete();
      await release.future;
    });
    await started.future;

    var drained = false;
    final close = gate.beginClose().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(
      gate.run<void>(() async {}),
      throwsA(isA<StateError>()),
    );

    release.complete();
    await mutation;
    await close;
    expect(drained, isTrue);
  });

  test('failed admitted mutation still releases close drain', () async {
    final gate = ExternalPluginMutationGate();
    final release = Completer<void>();
    final started = Completer<void>();
    final mutation = gate.run<void>(() async {
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
