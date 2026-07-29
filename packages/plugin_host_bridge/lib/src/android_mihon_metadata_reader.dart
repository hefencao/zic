import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

/// Reads Mihon-compatible APK identity and ABI metadata without class loading.
final class AndroidMihonApkMetadataReader implements MihonApkMetadataReader {
  const AndroidMihonApkMetadataReader({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const String _channelName = 'dev.zic/plugin_host_bridge';
  final MethodChannel _channel;

  @override
  Future<MihonApkMetadata> readMetadata(String apkPath) async {
    if (apkPath.trim().isEmpty) {
      throw ArgumentError.value(apkPath, 'apkPath');
    }
    final value = await _channel.invokeMapMethod<String, Object?>(
      'readMihonApkMetadata',
      <String, Object?>{'apkPath': apkPath},
    );
    if (value == null) {
      throw const FormatException('Android APK metadata response is empty');
    }
    final packageName = value['packageName'];
    final signerSha256 = value['signerSha256'];
    final versionCode = value['versionCode'];
    final extensionLib = value['extensionLib'];
    final rawEntryClasses = value['entryClasses'];
    if (rawEntryClasses is! List<Object?>) {
      throw const FormatException('Android APK entry metadata is invalid');
    }
    final entryClasses =
        rawEntryClasses.whereType<String>().toList(growable: false);
    if (packageName is! String ||
        packageName.trim().isEmpty ||
        signerSha256 is! String ||
        signerSha256.trim().isEmpty ||
        versionCode is! int ||
        versionCode < 0 ||
        extensionLib is! String ||
        extensionLib.trim().isEmpty ||
        entryClasses.isEmpty ||
        entryClasses.any((value) => value.trim().isEmpty) ||
        entryClasses.length != rawEntryClasses.length) {
      throw const FormatException('Android APK metadata response is invalid');
    }
    return MihonApkMetadata(
      packageName: packageName,
      signerSha256: signerSha256,
      versionCode: versionCode,
      extensionLib: extensionLib,
      entryClasses: entryClasses,
    );
  }
}
