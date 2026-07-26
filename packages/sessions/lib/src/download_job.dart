import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'download_session.dart';
import 'net_lane.dart';

final class DownloadJob {
  const DownloadJob({required this.transport, required this.session});

  final Transport transport;
  final DownloadSession session;

  Future<DownloadSnapshot> run({
    String? expectedChecksum,
    CancelToken? cancel,
  }) async {
    final lease = session.beginRun();
    try {
      cancel?.throwIfCancelled();
      await _run(expectedChecksum: expectedChecksum, cancel: cancel);
    } finally {
      session.endRun(lease);
    }
    return session.snapshot;
  }

  Future<void> _run({
    String? expectedChecksum,
    CancelToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    await session.restore();
    if (session.state == DownloadState.promoted) {
      return;
    }
    if (session.committedLength > 0 &&
        session.totalLength == session.committedLength) {
      final writer = session.acquireWriter();
      await session.seal(
        writer,
        expectedLength: session.totalLength,
        expectedChecksum: expectedChecksum,
      );
      await session.promote();
      return;
    }

    session.attach();
    session.queue();

    var start = session.committedLength;
    if (start > 0 && !session.validators.canResume) {
      session.recordResume(restarted: true);
      await session.reset();
      session.queue();
      start = 0;
    }
    cancel?.throwIfCancelled();
    var response = await _open(start);
    await _discardIfCancelled(cancel, response);
    if (start > 0) {
      try {
        requireResumeResponse(
          expectedStart: start,
          expectedValidators: session.validators,
          response: response,
        );
        session.recordResume(restarted: false);
      } on Failure catch (error) {
        if (error.code != ErrorCode.resumeRejected) {
          rethrow;
        }
        await response.discard();
        session.recordResume(restarted: true);
        await session.reset();
        session.queue();
        start = 0;
        cancel?.throwIfCancelled();
        response = await _open(0);
        await _discardIfCancelled(cancel, response);
      }
    }

    if (start == 0 && response.rangeStart != 0) {
      await response.discard();
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'full response did not start at offset zero',
      );
    }

    await session.bindResponse(
      validators: response.validators,
      totalLength: response.totalLength,
    );
    final writer = session.acquireWriter();
    var offset = session.committedLength;
    try {
      await for (final chunk in response.bytes) {
        cancel?.throwIfCancelled();
        await session.append(writer, offset, chunk);
        offset += chunk.length;
      }
      await session.seal(
        writer,
        expectedLength: response.totalLength,
        expectedChecksum: expectedChecksum,
      );
      await session.promote();
    } catch (error) {
      if (session.hasWriter) {
        await session.fail(writer, error);
      }
      rethrow;
    }
  }

  Future<void> _discardIfCancelled(
    CancelToken? cancel,
    ByteResponse response,
  ) async {
    if (cancel?.cancelled ?? false) {
      await response.discard();
      cancel!.throwIfCancelled();
    }
  }

  Future<ByteResponse> _open(int start) {
    if (start > 0 && session.validators.canResume) {
      return transport.open(
        session.id.canonicalUri,
        range: ByteRange(start: start),
        validators: session.validators,
      );
    }
    return transport.open(session.id.canonicalUri);
  }
}
