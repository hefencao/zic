import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_runtime/src/flutter_reader_touch_resampling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool originalEnabled;

  setUp(() {
    originalEnabled = GestureBinding.instance.resamplingEnabled;
  });

  tearDown(() {
    GestureBinding.instance.resamplingEnabled = originalEnabled;
  });

  test('vertical Reader lease enables and restores touch resampling', () {
    GestureBinding.instance.resamplingEnabled = false;

    final lease = FlutterReaderTouchResampling.acquire();
    expect(GestureBinding.instance.resamplingEnabled, isTrue);

    lease.release();
    expect(GestureBinding.instance.resamplingEnabled, isFalse);
  });

  test('nested Reader leases restore only after final release', () {
    GestureBinding.instance.resamplingEnabled = false;

    final first = FlutterReaderTouchResampling.acquire();
    final second = FlutterReaderTouchResampling.acquire();
    expect(GestureBinding.instance.resamplingEnabled, isTrue);

    first.release();
    expect(GestureBinding.instance.resamplingEnabled, isTrue);

    second.release();
    expect(GestureBinding.instance.resamplingEnabled, isFalse);
  });

  test('pre-existing resampling state is preserved after release', () {
    GestureBinding.instance.resamplingEnabled = true;

    final lease = FlutterReaderTouchResampling.acquire();
    expect(GestureBinding.instance.resamplingEnabled, isTrue);

    lease.release();
    expect(GestureBinding.instance.resamplingEnabled, isTrue);
  });
}
