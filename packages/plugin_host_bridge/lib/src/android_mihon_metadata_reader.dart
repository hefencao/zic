import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

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


final class InstalledMihonDiscoveryFailure {
  const InstalledMihonDiscoveryFailure({
    required this.packageName,
    required this.displayName,
    required this.stage,
    required this.errorType,
    required this.message,
  });

  final String packageName;
  final String displayName;
  final String stage;
  final String errorType;
  final String message;
}

final class InstalledMihonScan {
  const InstalledMihonScan({
    required this.extensions,
    required this.failures,
    required this.enumeratedPackageCount,
    required this.candidatePackageCount,
    required this.directProbeCount,
    required this.directMatchCount,
    required this.enumerationErrors,
    required this.visibilityLimited,
    required this.sharedExtensionOnly,
  });

  const InstalledMihonScan.empty()
      : extensions = const <InstalledMihonExtension>[],
        failures = const <InstalledMihonDiscoveryFailure>[],
        enumeratedPackageCount = 0,
        candidatePackageCount = 0,
        directProbeCount = 0,
        directMatchCount = 0,
        enumerationErrors = const <String>[],
        visibilityLimited = false,
        sharedExtensionOnly = true;

  final List<InstalledMihonExtension> extensions;
  final List<InstalledMihonDiscoveryFailure> failures;
  final int enumeratedPackageCount;
  final int candidatePackageCount;
  final int directProbeCount;
  final int directMatchCount;
  final List<String> enumerationErrors;
  final bool visibilityLimited;
  final bool sharedExtensionOnly;
}

/// Reads Mihon-compatible APK identity and ABI metadata without class loading.
final class AndroidMihonApkMetadataReader implements MihonApkMetadataReader {
  const AndroidMihonApkMetadataReader({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  static const String _channelName = 'dev.zic/plugin_host_bridge';
  final MethodChannel _channel;

  Future<List<InstalledMihonExtension>> listInstalled({
    Iterable<String> knownPackageNames = const <String>[],
  }) async =>
      (await scanInstalled(knownPackageNames: knownPackageNames)).extensions;

  Future<InstalledMihonScan> scanInstalled({
    Iterable<String> knownPackageNames = const <String>[],
  }) async {
    final packages = knownPackageNames
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false)
      ..sort();
    final value = await _channel.invokeMapMethod<String, Object?>(
      'scanInstalledMihonExtensions',
      <String, Object?>{'knownPackageNames': packages},
    );
    if (value == null) {
      throw const FormatException('Installed Mihon scan response is empty');
    }
    final rawExtensions = value['extensions'];
    final rawFailures = value['failures'];
    final rawEnumerationErrors = value['enumerationErrors'];
    if (rawExtensions is! List<Object?> ||
        rawFailures is! List<Object?> ||
        rawEnumerationErrors is! List<Object?>) {
      throw const FormatException('Installed Mihon scan response is invalid');
    }
    return InstalledMihonScan(
      extensions: List<InstalledMihonExtension>.unmodifiable(
        rawExtensions.map(_installedExtension),
      ),
      failures: List<InstalledMihonDiscoveryFailure>.unmodifiable(
        rawFailures.map(_installedFailure),
      ),
      enumeratedPackageCount: _requiredNonNegativeInt(
        value,
        'enumeratedPackageCount',
      ),
      candidatePackageCount: _requiredNonNegativeInt(
        value,
        'candidatePackageCount',
      ),
      directProbeCount: _requiredNonNegativeInt(value, 'directProbeCount'),
      directMatchCount: _requiredNonNegativeInt(value, 'directMatchCount'),
      enumerationErrors: List<String>.unmodifiable(
        rawEnumerationErrors.map((item) {
          if (item is! String || item.trim().isEmpty) {
            throw const FormatException(
              'Installed Mihon enumeration error is invalid',
            );
          }
          return item;
        }),
      ),
      visibilityLimited: value['visibilityLimited'] == true,
      sharedExtensionOnly: value['sharedExtensionOnly'] != false,
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

InstalledMihonDiscoveryFailure _installedFailure(Object? raw) {
  if (raw is! Map<Object?, Object?> ||
      raw.keys.any((key) => key is! String)) {
    throw const FormatException('Installed Mihon failure response is invalid');
  }
  final value = Map<String, Object?>.from(raw);
  String field(String key) {
    final result = value[key];
    if (result is! String || result.trim().isEmpty) {
      throw const FormatException('Installed Mihon failure field is invalid');
    }
    return result;
  }
  return InstalledMihonDiscoveryFailure(
    packageName: field('packageName'),
    displayName: field('displayName'),
    stage: field('stage'),
    errorType: field('errorType'),
    message: field('message'),
  );
}

int _requiredNonNegativeInt(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! int || result < 0) {
    throw const FormatException('Installed Mihon scan count is invalid');
  }
  return result;
}
