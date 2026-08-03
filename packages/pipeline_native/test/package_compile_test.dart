import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline_native/pipeline_native.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

void main() {
  test('native Pipeline media capability is atomically injectable', () {
    final factory = NativePipelineMediaRuntimeFactory();
    expect(factory, isA<PipelineMediaRuntimeFactory>());
  });
}
