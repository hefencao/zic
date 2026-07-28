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
