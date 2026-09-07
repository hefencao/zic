import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  testWidgets('one page cannot register local bytes and origin response together',
      (tester) async {
    const sourceId = 'memory:page';
    await tester.pumpWidget(
      MaterialApp(
        home: ImportedImageChapterScreen(
          record: ImportedChapterRecord(
            directoryId: 'test',
            displayName: 'test',
            sourceId: 'remote',
            comicId: 'comic',
            chapterId: 'chapter',
            sourceRevision: 'r1',
            pages: const <ImportedPageRecord>[
              ImportedPageRecord(
                displayName: '1.bin',
                sourceId: sourceId,
                pageId: 'page-1',
                contentKindHint: ContentKindHint.unknown,
              ),
            ],
          ),
          byteLoaders: <String, LocalImageFileBytesLoader>{
            sourceId: () async => Uint8List(1),
          },
          responseSources: <String, LocalImageResponseSource>{
            sourceId: LocalImageResponseSource(
              openControlledResponse: ({range, validators, control}) async =>
                  ByteResponse(
                bytes: const Stream<List<int>>.empty(),
                statusCode: 200,
                rangeStart: 0,
                totalLength: 0,
              ),
            ),
          },
          pipelineFactory: PipelineReaderSessionFactory(
            mediaRuntimeFactory: _NeverMediaRuntimeFactory(),
          ),
        ),
      ),
    );

    expect(
      tester.takeException(),
      isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('local bytes or origin response'),
      ),
    );
  });
}

final class _NeverMediaRuntimeFactory implements PipelineMediaRuntimeFactory {
  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      throw StateError('media runtime must not be created for invalid source composition');
}
