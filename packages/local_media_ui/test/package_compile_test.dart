import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';

void main() {
  test('local media UI package composition compiles', () {
    expect(
      defaultLocalMediaPipelineFactory,
      isA<PipelineReaderSessionFactory>(),
    );
  });
}
