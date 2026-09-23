import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/src/reader_route_transition_gate.dart';

final class _GateProbe extends StatefulWidget {
  const _GateProbe({required this.onApply});

  final VoidCallback onApply;

  @override
  State<_GateProbe> createState() => _GateProbeState();
}

final class _GateProbeState extends State<_GateProbe> {
  late final ReaderRouteTransitionGate _gate = ReaderRouteTransitionGate(
    widget.onApply,
  );

  @override
  Widget build(BuildContext context) {
    _gate.schedule(context);
    return const SizedBox.expand();
  }

  @override
  void dispose() {
    _gate.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets('first apply waits for the entering route transition', (
    tester,
  ) async {
    var applications = 0;
    const launchKey = ValueKey<String>('gate-launch');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            key: launchKey,
            onPressed: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                transitionDuration: const Duration(seconds: 2),
                pageBuilder: (context, animation, secondaryAnimation) =>
                    _GateProbe(onApply: () => applications++),
              ),
            ),
            child: const Text('Launch'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(launchKey));
    await tester.pump();
    expect(applications, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(applications, 0);
    await tester.pumpAndSettle();
    expect(applications, 1);
  });

  testWidgets('applyNow reapplies after the initial route commit', (
    tester,
  ) async {
    var applications = 0;
    final gate = ReaderRouteTransitionGate(() => applications++);
    addTearDown(gate.dispose);

    gate.applyNow();
    gate.applyNow();

    expect(applications, 2);
  });
}
