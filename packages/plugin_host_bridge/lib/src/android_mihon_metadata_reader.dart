import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';


final class ExternalLoginSnapshot {
  ExternalLoginSnapshot({
    required this.currentUrl,
    required this.title,
    required Map<String, String> cookies,
    required Map<String, String> localStorage,
  })  : cookies = Map<String, String>.unmodifiable(cookies),
        localStorage = Map<String, String>.unmodifiable(localStorage);

  final Uri currentUrl;
  final String title;
  final Map<String, String> cookies;
  final Map<String, String> localStorage;
}

final class InstalledMihonExtension {
  InstalledMihonExtension({
    required this.packageName,
    required this.displayName,
    required this.versionName,
    required this.versionCode,
    required this.signerSha256,
    required this.extensionLib,
    required this.extensionLibSource,
    required this.declaredExtensionLib,
    required Iterable<String> entryClasses,
  }) : entryClasses = List<String>.unmodifiable(entryClasses);

  final String packageName;
  final String displayName;
  final String versionName;
  final int versionCode;
  final String signerSha256;
  final String extensionLib;
  final String extensionLibSource;
  final String? declaredExtensionLib;
  final List<String> entryClasses;
}

/// Reads Mihon-compatible APK identity and ABI metadata without class loading.
final class AndroidMihonApkMetadataReader implements MihonApkMetadataReader {
  const AndroidMihonApkMetadataReader({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const String _channelName = 'dev.zic/plugin_host_bridge';
  final MethodChannel _channel;

  Future<List<InstalledMihonExtension>> listInstalled() async {
    final values = await _channel.invokeListMethod<Object?>(
      'listInstalledMihonExtensions',
    );
    if (values == null) return const <InstalledMihonExtension>[];
    return List<InstalledMihonExtension>.unmodifiable(
      values.map(_installedExtension),
    );
  }

  Future<void> copyInstalled({
    required String packageName,
    required String destinationPath,
  }) async {
    if (packageName.trim().isEmpty || destinationPath.trim().isEmpty) {
      throw ArgumentError('packageName and destinationPath are required');
    }
    await _channel.invokeMapMethod<String, Object?>(
      'copyInstalledMihonExtension',
      <String, Object?>{
        'packageName': packageName,
        'destinationPath': destinationPath,
      },
    );
  }

  Future<void> openLogin(Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') {
      throw ArgumentError.value(url, 'url', 'must use HTTP(S)');
    }
    await _channel.invokeMethod<void>(
      'openMihonLogin',
      <String, Object?>{'url': url.toString()},
    );
  }

  Future<ExternalLoginSnapshot?> readLoginSnapshot(Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') {
      throw ArgumentError.value(url, 'url', 'must use HTTP(S)');
    }
    final value = await _channel.invokeMapMethod<String, Object?>(
      'readExternalLoginSnapshot',
      <String, Object?>{'url': url.toString()},
    );
    if (value == null) return null;
    final currentUrl = value['currentUrl'];
    final title = value['title'];
    if (currentUrl is! String || title is! String) {
      throw const FormatException('Android login snapshot is invalid');
    }
    final parsedUrl = Uri.tryParse(currentUrl);
    if (parsedUrl == null ||
        (parsedUrl.scheme != 'https' && parsedUrl.scheme != 'http')) {
      throw const FormatException('Android login snapshot URL is invalid');
    }
    Map<String, String> parseStringMap(Object? raw, String label) {
      if (raw == null) return const <String, String>{};
      if (raw is! Map) throw FormatException('$label is invalid');
      final result = <String, String>{};
      for (final entry in raw.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw FormatException('$label is invalid');
        }
        result[entry.key as String] = entry.value as String;
      }
      return result;
    }
    return ExternalLoginSnapshot(
      currentUrl: parsedUrl,
      title: title,
      cookies: parseStringMap(value['cookies'], 'Android login cookies'),
      localStorage: parseStringMap(
        value['localStorage'],
        'Android login local storage',
      ),
    );
  }

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

InstalledMihonExtension _installedExtension(Object? raw) {
  if (raw is! Map<Object?, Object?> ||
      raw.keys.any((key) => key is! String)) {
    throw const FormatException('Installed Mihon extension response is invalid');
  }
  final value = Map<String, Object?>.from(raw);
  final packageName = value['packageName'];
  final displayName = value['displayName'];
  final versionName = value['versionName'];
  final versionCode = value['versionCode'];
  final signerSha256 = value['signerSha256'];
  final extensionLib = value['extensionLib'];
  final extensionLibSource = value['extensionLibSource'];
  final declaredExtensionLib = value['declaredExtensionLib'];
  final rawEntryClasses = value['entryClasses'];
  if (packageName is! String ||
      packageName.trim().isEmpty ||
      displayName is! String ||
      displayName.trim().isEmpty ||
      versionName is! String ||
      versionName.trim().isEmpty ||
      versionCode is! int ||
      versionCode < 0 ||
      signerSha256 is! String ||
      signerSha256.trim().isEmpty ||
      extensionLib is! String ||
      extensionLib.trim().isEmpty ||
      extensionLibSource is! String ||
      !const <String>{'manifest', 'versionName'}.contains(extensionLibSource) ||
      (declaredExtensionLib != null &&
          (declaredExtensionLib is! String ||
              declaredExtensionLib.trim().isEmpty)) ||
      rawEntryClasses is! List<Object?>) {
    throw const FormatException('Installed Mihon extension response is invalid');
  }
  final entryClasses =
      rawEntryClasses.whereType<String>().toList(growable: false);
  if (entryClasses.isEmpty ||
      entryClasses.any((value) => value.trim().isEmpty) ||
      entryClasses.length != rawEntryClasses.length) {
    throw const FormatException('Installed Mihon extension response is invalid');
  }
  return InstalledMihonExtension(
    packageName: packageName,
    displayName: displayName,
    versionName: versionName,
    versionCode: versionCode,
    signerSha256: signerSha256,
    extensionLib: extensionLib,
    extensionLibSource: extensionLibSource,
    declaredExtensionLib: declaredExtensionLib as String?,
    entryClasses: entryClasses,
  );
}
