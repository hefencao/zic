import 'package:catalog/catalog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:storage/storage.dart';

Future<ImportedLibraryStore> openDefaultImportedLibraryStore() async {
  final support = await getApplicationSupportDirectory();
  final store = SqliteImportedLibraryStore(
    '${support.path}/zic/imported_library.sqlite3',
  );
  await store.open();
  return store;
}
