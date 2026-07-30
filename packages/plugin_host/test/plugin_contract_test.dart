import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('activation exception includes the native runtime cause', () {
    final error = ExternalPluginActivationException(
      pluginId: 'mihon:example',
      denials: const <ExternalPluginDenial>{
        ExternalPluginDenial.activationFailed,
      },
      cause: StateError(
        'Mihon entry activation failed: ExampleSource: missing dependency',
      ),
    );

    expect(error.toString(), contains('activationFailed'));
    expect(error.toString(), contains('ExampleSource'));
    expect(error.toString(), contains('missing dependency'));
  });
}
