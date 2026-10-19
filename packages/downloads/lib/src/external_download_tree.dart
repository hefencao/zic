import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'artifact_bytes.dart';

/// An import source is deliberately read-only. Paths are relative to one grant.
abstract interface class ExternalDownloadTree {
  String get identity;
  String get displayName;
  Future<List<ExternalDownloadFile>> list(String directory);
  Stream<List<int>> read(String path);
}

final class ExternalDownloadFile {
  const ExternalDownloadFile(this.name, {this.isDirectory = false, this.length});
  final String name;
  final bool isDirectory;
  final int? length;
}

String checkedExternalPath(String path, {bool allowRoot = false}) {
  if (allowRoot && path.isEmpty) return path;
  if (path.isEmpty || path.contains('\\') || path.contains('\u0000') ||
      path.split('/').any((part) =>
          part.isEmpty || part == '.' || part == '..' || part.contains(':'))) {
    throw FormatException('不安全的导入路径：$path');
  }
  return path;
}

String externalChildPath(String parent, String name) {
  checkedExternalPath(name);
  if (name.contains('/')) throw FormatException('无效的文件名：$name');
  return checkedExternalPath(parent.isEmpty ? name : '$parent/$name');
}

final class DirectoryExternalDownloadTree implements ExternalDownloadTree {
  DirectoryExternalDownloadTree(String root) : root = Directory(root).absolute;
  final Directory root;
  @override
  String get identity => root.path;
  @override
  String get displayName => p.basename(root.path);

  Future<String> _resolve(String path) async {
    checkedExternalPath(path, allowRoot: true);
    final canonicalRoot = await root.resolveSymbolicLinks();
    var current = canonicalRoot;
    for (final part in path.isEmpty ? const <String>[] : path.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FormatException('导入不跟随符号链接：$path');
      }
    }
    final canonical = await File(current).resolveSymbolicLinks();
    if (canonical != canonicalRoot && !p.isWithin(canonicalRoot, canonical)) {
      throw FormatException('路径超出选择的目录：$path');
    }
    return canonical;
  }

  @override
  Future<List<ExternalDownloadFile>> list(String directory) async {
    final result = <ExternalDownloadFile>[];
    await for (final entity in Directory(await _resolve(directory)).list(
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.file) {
        continue;
      }
      result.add(ExternalDownloadFile(
        p.basename(entity.path),
        isDirectory: type == FileSystemEntityType.directory,
        length: type == FileSystemEntityType.file
            ? (await entity.stat()).size : null,
      ));
    }
    return result;
  }

  @override
  Stream<List<int>> read(String path) async* {
    yield* File(await _resolve(path)).openRead();
  }
}

final class SafExternalDownloadTree implements ExternalDownloadTree {
  SafExternalDownloadTree({required this.io, required this.identity,
    required this.displayName});
  final SafTreeIo io;
  @override
  final String identity;
  @override
  final String displayName;

  @override
  Future<List<ExternalDownloadFile>> list(String directory) async => [
    for (final file in await io.list(
      checkedExternalPath(directory, allowRoot: true),
    ))
      ExternalDownloadFile(file.name,
        isDirectory: file.isDirectory, length: file.length),
  ];

  @override
  Stream<Uint8List> read(String path) async* {
    final handle = await io.open(checkedExternalPath(path));
    if (handle == null) throw FileSystemException('无法读取导入文件', path);
    try {
      while (true) {
        final bytes = await io.read(handle, 64 * 1024);
        if (bytes.isEmpty) break;
        yield bytes;
      }
    } finally {
      await io.close(handle);
    }
  }
}
