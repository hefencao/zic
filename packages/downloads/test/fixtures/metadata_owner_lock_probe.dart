import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args.single).open(mode: FileMode.append);
  try {
    await handle.lock(FileLock.exclusive);
    stdout.write('acquired');
    await handle.unlock();
  } on FileSystemException {
    stdout.write('blocked');
  } finally {
    await handle.close();
  }
}
