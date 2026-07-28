import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';

Future<List<XFile>> listLocalWebpDirectory(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) {
    throw FileSystemException('文件夹不存在', path);
  }

  final paths = await Isolate.run(() => _scanWebpPaths(path));
  return List<XFile>.unmodifiable(paths.map((path) => XFile(path)));
}

Future<List<String>> _scanWebpPaths(String path) async {
  final paths = <String>[];
  await for (final entity in Directory(path).list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && entity.path.toLowerCase().endsWith('.webp')) {
      paths.add(entity.path);
    }
  }
  paths.sort(_naturalPathCompare);
  return paths;
}

int _naturalPathCompare(String left, String right) {
  final a = left.replaceAll('\\', '/').toLowerCase();
  final b = right.replaceAll('\\', '/').toLowerCase();
  var ai = 0;
  var bi = 0;
  while (ai < a.length && bi < b.length) {
    final aDigit = _isDigit(a.codeUnitAt(ai));
    final bDigit = _isDigit(b.codeUnitAt(bi));
    if (aDigit && bDigit) {
      final aStart = ai;
      final bStart = bi;
      while (ai < a.length && _isDigit(a.codeUnitAt(ai))) {
        ai++;
      }
      while (bi < b.length && _isDigit(b.codeUnitAt(bi))) {
        bi++;
      }
      final aNumber = int.tryParse(a.substring(aStart, ai));
      final bNumber = int.tryParse(b.substring(bStart, bi));
      if (aNumber != null && bNumber != null && aNumber != bNumber) {
        return aNumber.compareTo(bNumber);
      }
      final digitLength = (ai - aStart).compareTo(bi - bStart);
      if (digitLength != 0) {
        return digitLength;
      }
      continue;
    }
    final order = a.codeUnitAt(ai).compareTo(b.codeUnitAt(bi));
    if (order != 0) {
      return order;
    }
    ai++;
    bi++;
  }
  return a.length.compareTo(b.length);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
