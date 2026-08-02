import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_bridge/network_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.zic/network_bridge');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('opens an HTTP source browser through the shared bridge', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await const AndroidNetworkBridge(channel: channel).openBrowser(
      Uri.parse('https://example.test/login'),
    );

    expect(received?.method, 'openBrowser');
    expect(received?.arguments, <String, Object?>{
      'url': 'https://example.test/login',
    });
  });

  test('binds a source-owned user agent to the browser request', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await const AndroidNetworkBridge(channel: channel).openBrowser(
      Uri.parse('https://example.test/login'),
      userAgent: 'source-owned-agent',
    );

    expect(received?.arguments, <String, Object?>{
      'url': 'https://example.test/login',
      'userAgent': 'source-owned-agent',
    });
  });

  test('maps a bounded browser snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'currentUrl': 'https://example.test/verified',
              'title': 'Verified',
              'cookies': <String, String>{'cf_clearance': 'token'},
              'localStorage': <String, String>{'session': 'ready'},
              'userAgent': 'source-owned-agent',
            });

    final snapshot = await const AndroidNetworkBridge(channel: channel)
        .readBrowserSnapshot(Uri.parse('https://example.test/login'));

    expect(snapshot?.currentUrl, Uri.parse('https://example.test/verified'));
    expect(snapshot?.title, 'Verified');
    expect(snapshot?.cookies['cf_clearance'], 'token');
    expect(snapshot?.localStorage['session'], 'ready');
    expect(snapshot?.userAgent, 'source-owned-agent');
  });

  test('rejects non HTTP browser locations before platform dispatch', () async {
    expect(
      const AndroidNetworkBridge(channel: channel)
          .openBrowser(Uri.parse('file:///tmp/login.html')),
      throwsArgumentError,
    );
  });
}
