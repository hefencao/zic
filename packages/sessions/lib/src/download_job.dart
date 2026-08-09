import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'download_session.dart';
import 'net_lane.dart';
import 'source_progress.dart';

final class DownloadJob {
  const DownloadJob({
    required this.transport,
    required this.session,
  });

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
    if (session.state == DownloadState.promoted) {
      return;
    }
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
    var response = await _open(start, cancel);
    await _discardIfCancelled(cancel, response);
    if (start > 0 &&
        response.disposition == ByteResponseDisposition.durableImmutable) {
      await response.discard();
      session.recordResume(restarted: true);
      await session.reset();
      session.queue();
      start = 0;
      cancel?.throwIfCancelled();
      response = await _open(0, cancel);
      await _discardIfCancelled(cancel, response);
    }
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
        response = await _open(0, cancel);
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

    if (start == 0 && response.totalLength == 0) {
      await response.discard();
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'image response body is empty',
      );
    }

    if (start == 0 &&
        response.disposition == ByteResponseDisposition.durableImmutable &&
        response.totalLength != null) {
      session.beginDurableCachedIngress(
        validators: response.validators,
        totalLength: response.totalLength!,
        residentSource: _residentSourceFor(session.id.canonicalUri),
      );
      var residentOffset = 0;
      final residentIterator = StreamIterator<List<int>>(response.bytes);
      try {
        while (await _moveNext(residentIterator, cancel)) {
          final chunk = residentIterator.current;
          if (chunk.isEmpty) continue;
          session.appendDurableCachedIngress(residentOffset, chunk);
          residentOffset += chunk.length;
          await Future<void>.delayed(Duration.zero);
        }
        session.sealDurableCachedIngress();
        return;
      } catch (_) {
        await residentIterator.cancel();
        await session.reset();
        rethrow;
      }
    }

    await session.bindResponse(
      validators: response.validators,
      totalLength: response.totalLength,
    );
    final writer = session.acquireWriter();
    var offset = session.committedLength;
    final iterator = StreamIterator<List<int>>(response.bytes);
    final pending = BytesBuilder(copy: false);
    var flushTarget = 16 * 1024;
    Future<void> flushPending() async {
      if (pending.length == 0) return;
      final bytes = pending.takeBytes();
      await session.append(writer, offset, bytes);
      offset += bytes.length;
      flushTarget = sourceProgressQuantumBytes;
    }
    try {
      while (await _moveNext(iterator, cancel)) {
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        pending.add(chunk);
        if (pending.length >= flushTarget) {
          await flushPending();
        }
      }
      await flushPending();
      if (offset <= 0) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'image response produced no bytes',
        );
      }
      await session.seal(
        writer,
        expectedLength: response.totalLength,
        expectedChecksum: expectedChecksum,
      );
      await session.promote();
    } catch (error) {
      // Preserve bytes already delivered by the transport so resume semantics
      // remain independent of the transport's arbitrary chunk size.
      try {
        await flushPending();
      } on Object {
        // The original failure remains authoritative; session.fail closes the
        // writer and records the recoverable partial state below.
      }
      await iterator.cancel();
      if (session.hasWriter) {
        await session.fail(writer, error);
      }
      rethrow;
    }
  }


  String _residentSourceFor(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'file' || scheme == 'content' || scheme == 'asset'
        ? 'local-immutable'
        : 'durable-cache';
  }

  Future<bool> _moveNext(
    StreamIterator<List<int>> iterator,
    CancelToken? cancel,
  ) async {
    if (cancel == null) {
      return iterator.moveNext();
    }
    cancel.throwIfCancelled();
    final result = await Future.any<Object>(<Future<Object>>[
      iterator.moveNext().then<Object>(_NextChunk.new),
      cancel.whenCancelled.then<Object>((_) => const _DownloadCancelled()),
    ]);
    if (result is _DownloadCancelled) {
      await iterator.cancel();
      cancel.throwIfCancelled();
    }
    return (result as _NextChunk).available;
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

  Future<ByteResponse> _open(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    if (start > 0 && session.validators.canResume) {
      if (controlled != null) {
        return controlled.openControlled(
          session.id.canonicalUri,
          range: ByteRange(start: start),
          validators: session.validators,
          control: cancel,
        );
      }
      return transport.open(
        session.id.canonicalUri,
        range: ByteRange(start: start),
        validators: session.validators,
      );
    }
    if (controlled != null) {
      return controlled.openControlled(
        session.id.canonicalUri,
        control: cancel,
      );
    }
    return transport.open(session.id.canonicalUri);
  }
}

final class _NextChunk {
  const _NextChunk(this.available);

  final bool available;
}

final class _DownloadCancelled {
  const _DownloadCancelled();
}
