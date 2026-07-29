import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:storage/storage.dart';

Future<String> getDefaultZicStorageRoot() async {
  final support = await getApplicationSupportDirectory();
  return '${support.path}/zic';
}

Future<ImportedLibraryStore> openDefaultImportedLibraryStore() async {
  final root = await getDefaultZicStorageRoot();
  final store = SqliteImportedLibraryStore(
    '$root/imported_library.sqlite3',
  );
  await store.open();
  return store;
}

Future<Map<String, Object?>?> readJsonObjectFile(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return null;
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<Object?, Object?>) {
    throw const FormatException('JSON document root must be an object');
  }
  return decoded.cast<String, Object?>();
}

Future<void> writeJsonObjectFile(
  String path,
  Map<String, Object?> data,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final temporary = File('$path.tmp');
  await temporary.writeAsString(jsonEncode(data), flush: true);
  if (await file.exists()) {
    await file.delete();
  }
  await temporary.rename(path);
}
