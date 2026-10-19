part of 'external_download_import.dart';

({List<String> pages, _ExternalMetadata metadata}) _inspectArchive(String path) {
  final input = InputFileStream(path);
  try {
    final directory = _checkedZipDirectory(input);
    final pages = directory.fileHeaders.where((f) => !f.filename.endsWith('/') && _isExternalPage(
      p.posix.basename(f.filename),
    ) && !f.filename.split('/').any(_skipExternalName))
        .map((f) => f.filename).toList()..sort(_naturalCompare);
    final infos = directory.fileHeaders.where((f) =>
        p.posix.basename(f.filename).toLowerCase() == 'comicinfo.xml').toList();
    var metadata = const _ExternalMetadata();
    if (infos.length == 1) {
      if (infos.single.uncompressedSize > _maxMetadataBytes) {
        throw const FormatException('压缩包 ComicInfo 过大');
      }
      final output = OutputMemoryStream();
      infos.single.file!.decompress(output);
      final bytes = output.getBytes();
      _verifyZipBytes(infos.single, bytes);
      metadata = _readComicInfo(Uint8List.fromList(bytes));
    } else if (infos.length > 1) {
      throw const FormatException('压缩包存在多个 ComicInfo，无法确定漫画归属');
    }
    return (pages: pages, metadata: metadata);
  } finally {
    input.closeSync();
  }
}

ZipDirectory _checkedZipDirectory(InputFileStream input) {
  if (input.length > _maxArchiveBytes) throw const FormatException('压缩包过大');
  _preflightZipDirectory(input);
  final directory = ZipDirectory()..read(input);
  if (directory.filePosition < 0 || directory.fileHeaders.length > _maxEntries ||
      directory.numberOfThisDisk != 0) {
    throw const FormatException('无效或过大的 CBZ');
  }
  var total = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    final name = header.filename;
    checkedExternalPath(name.endsWith('/') ? name.substring(0, name.length - 1) : name);
    if (!names.add(name.toLowerCase()) || header.file?.filename != name) {
      throw const FormatException('CBZ 文件名重复或头部不一致');
    }
    final type = (header.externalFileAttributes >> 16) & 0xf000;
    if (type == 0xa000 || (header.generalPurposeBitFlag & 1) != 0 ||
        ((header.file?.flags ?? 0) & 1) != 0) {
      throw const FormatException('CBZ 不支持符号链接或加密内容');
    }
    if (header.uncompressedSize < 0 || header.uncompressedSize > _maxPageBytes ||
        !{0, 8}.contains(header.compressionMethod)) {
      throw const FormatException('CBZ 图片大小或压缩方式不受支持');
    }
    total += header.uncompressedSize;
    if (total > _maxArchiveBytes) throw const FormatException('CBZ 解压内容过大');
  }
  return directory;
}

// Bound central-directory parsing before the archive package allocates entry
// objects. CBZs requiring ZIP64 exceed this importer's page/entry limits.
void _preflightZipDirectory(InputFileStream input) {
  final length = input.length;
  if (length < 22) throw const FormatException('CBZ 头部不完整');
  final tailLength = length.clamp(0, 65557);
  final tail = input.subset(position: length - tailLength, length: tailLength).toUint8List();
  final data = ByteData.sublistView(tail);
  var end = -1;
  for (var i = tail.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0 || end + 22 + data.getUint16(end + 20, Endian.little) != tail.length) {
    throw const FormatException('CBZ 目录尾部无效');
  }
  final entries = data.getUint16(end + 10, Endian.little);
  final size = data.getUint32(end + 12, Endian.little);
  final offset = data.getUint32(end + 16, Endian.little);
  if (data.getUint16(end + 4, Endian.little) != 0 ||
      data.getUint16(end + 6, Endian.little) != 0 ||
      data.getUint16(end + 8, Endian.little) != entries ||
      entries > _maxEntries || size > 32 * 1024 * 1024 ||
      offset + size > length - tailLength + end) {
    throw const FormatException('CBZ 目录过大或分卷/ZIP64 不受支持');
  }
  var count = 0;
  var position = offset;
  while (position < offset + size) {
    if (++count > _maxEntries || offset + size - position < 46) {
      throw const FormatException('CBZ 目录项目过多或不完整');
    }
    input.setPosition(position);
    if (input.readUint32() != 0x02014b50) throw const FormatException('无效的 CBZ 文件头');
    input.setPosition(position + 28);
    final nameLength = input.readUint16();
    final extraLength = input.readUint16();
    final commentLength = input.readUint16();
    position += 46 + nameLength + extraLength + commentLength;
    if (position > offset + size) throw const FormatException('CBZ 目录越界');
  }
  if (count != entries) throw const FormatException('CBZ 目录数量不一致');
  input.setPosition(0);
}

void _verifyZipBytes(ZipFileHeader header, List<int> bytes) {
  final crc = Crc32()..add(bytes);
  if (bytes.length != header.uncompressedSize || crc.value != header.crc32) {
    throw const FormatException('CBZ 文件长度或 CRC 校验失败');
  }
}

Future<({List<String> pages, _ExternalMetadata metadata})> _inspectExternalArchive(
    ExternalDownloadTree tree, String path, void Function() check) async {
  final temp = await Directory.systemTemp.createTemp('zic-import-archive-');
  try {
    final file = File(p.join(temp.path, 'input.cbz'));
    await _copyExternalFile(tree, path, file, _maxArchiveBytes, check);
    final result = await _externalWorker(file.path, _inspectArchive);
    check();
    return result;
  } finally {
    await temp.delete(recursive: true);
  }
}

void _extractExternalPage(({String archive, String name, String target}) paths) {
  final input = InputFileStream(paths.archive);
  try {
    final directory = _checkedZipDirectory(input);
    final header = directory.fileHeaders.singleWhere((f) => f.filename == paths.name);
    final output = OutputFileStream(paths.target);
    try {
      header.file!.decompress(output);
    } finally {
      output.closeSync();
    }
    final file = File(paths.target);
    final crc = Crc32();
    final read = file.openSync();
    try {
      while (true) {
        final bytes = read.readSync(64 * 1024);
        if (bytes.isEmpty) break;
        crc.add(bytes);
      }
    } finally {
      read.closeSync();
    }
    if (file.lengthSync() != header.uncompressedSize || crc.value != header.crc32) {
      throw const FormatException('CBZ 图片长度或 CRC 校验失败');
    }
  } finally {
    input.closeSync();
  }
}
