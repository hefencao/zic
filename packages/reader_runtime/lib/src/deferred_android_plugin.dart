import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _startupPlatformChannel = MethodChannel(
  'dev.zic.zic/startup',
);

Future<void>? _readerRuntimeAttachment;

Future<void> ensureReaderRuntimePluginAttached() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  final existing = _readerRuntimeAttachment;
  if (existing != null) {
    await existing;
    return;
  }
  final future = _startupPlatformChannel.invokeMethod<void>(
    'attachPlugin',
    const <String, Object?>{'name': 'reader_runtime'},
  );
  _readerRuntimeAttachment = future;
  try {
    await future;
  } on MissingPluginException {
    // The app startup channel is optional outside the Android app shell.
  } on Object {
    if (identical(_readerRuntimeAttachment, future)) {
      _readerRuntimeAttachment = null;
    }
    rethrow;
  }
}
