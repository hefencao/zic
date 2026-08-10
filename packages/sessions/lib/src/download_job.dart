import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:transport/transport.dart';

import 'download_session.dart';
import 'net_lane.dart';
import 'source_progress.dart';

const int _validatorlessResumeProbeBytes = 64 * 1024;

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

    final preservedLength = session.committedLength;
    final preservedTotalLength = session.totalLength;
    var start = preservedLength;
    var fullBodyCatchup = false;
    var validatorlessRangeProbe = false;
    var probeStart = 0;
    var probeBytes = 0;
    ByteResponse response;
    cancel?.throwIfCancelled();
    if (start > 0 && !session.validators.canResume) {
      if (preservedTotalLength != null && preservedTotalLength >= start) {
        probeBytes = start < _validatorlessResumeProbeBytes
            ? start
            : _validatorlessResumeProbeBytes;
        probeStart = start - probeBytes;
        response = await _openRange(probeStart, cancel);
        await _discardIfCancelled(cancel, response);
        final usableProbe = response.isPartial &&
            response.rangeStart == probeStart &&
            response.totalLength == preservedTotalLength;
        if (usableProbe) {
          validatorlessRangeProbe = true;
        } else if (response.statusCode == 200 && response.rangeStart == 0) {
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': response.statusCode,
              'resumeProbeAccepted': false,
              'duplicatePrefixBytes': 0,
              'fullBodyResponseReused': true,
            },
          );
        } else {
          final probeStatusCode = response.statusCode;
          await response.discard();
          cancel?.throwIfCancelled();
          response = await _open(0, cancel);
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': probeStatusCode,
              'resumeProbeAccepted': false,
              'duplicatePrefixBytes': 0,
              'fullBodyResponseReused': false,
            },
          );
        }
      } else {
        response = await _open(0, cancel);
        fullBodyCatchup = true;
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup',
          playablePrefixPreserved: true,
          diagnostics: const <String, Object?>{
            'resumeProbeAttempted': false,
            'duplicatePrefixBytes': 0,
          },
        );
      }
    } else {
      response = await _open(start, cancel);
      await _discardIfCancelled(cancel, response);
      if (start > 0 &&
          response.disposition == ByteResponseDisposition.durableImmutable) {
        if (response.statusCode == 200 && response.rangeStart == 0) {
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': true,
              'duplicatePrefixBytes': 0,
            },
          );
        } else {
          await response.discard();
          cancel?.throwIfCancelled();
          response = await _open(0, cancel);
          fullBodyCatchup = true;
          session.recordResume(
            restarted: true,
            strategy: 'full-body-prefix-catchup',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': false,
              'duplicatePrefixBytes': 0,
            },
          );
        }
      } else if (start > 0) {
        try {
          requireResumeResponse(
            expectedStart: start,
            expectedValidators: session.validators,
            response: response,
          );
          session.recordResume(
            restarted: false,
            strategy: 'strong-validator-range',
            playablePrefixPreserved: true,
            diagnostics: const <String, Object?>{
              'duplicatePrefixBytes': 0,
            },
          );
        } on Failure catch (error) {
          if (error.code != ErrorCode.resumeRejected) {
            rethrow;
          }
          if (response.statusCode == 200 && response.rangeStart == 0) {
            fullBodyCatchup = true;
            session.recordResume(
              restarted: true,
              strategy: 'full-body-prefix-catchup',
              playablePrefixPreserved: true,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': true,
                'duplicatePrefixBytes': 0,
              },
            );
          } else {
            await response.discard();
            cancel?.throwIfCancelled();
            response = await _open(0, cancel);
            fullBodyCatchup = true;
            session.recordResume(
              restarted: true,
              strategy: 'full-body-prefix-catchup',
              playablePrefixPreserved: true,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': false,
                'duplicatePrefixBytes': 0,
              },
            );
          }
        }
      }
    }
    await _discardIfCancelled(cancel, response);

    if ((start == 0 || fullBodyCatchup) && response.rangeStart != 0) {
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

    final writer = session.acquireWriter();
    var offset = session.committedLength;
    final iterator = StreamIterator<List<int>>(response.bytes);
    List<int> catchupRemainder = const <int>[];
    if (validatorlessRangeProbe) {
      var duplicatePrefixBytes = 0;
      try {
        catchupRemainder = await _verifyArtifactOverlap(
          iterator: iterator,
          probeStart: probeStart,
          preservedLength: preservedLength,
          cancel: cancel,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
          },
        );
      } catch (error) {
        session.recordResume(
          restarted: true,
          strategy: 'validatorless-range-probe-rejected',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'resumeProbeStart': probeStart,
            'resumeProbeBytes': probeBytes,
            'resumeProbeStatusCode': response.statusCode,
            'resumeProbeAccepted': false,
            'duplicatePrefixBytes': duplicatePrefixBytes,
          },
        );
        await iterator.cancel();
        if (session.hasWriter) {
          await session.fail(writer, error);
        }
        rethrow;
      }
      session.recordResume(
        restarted: false,
        strategy: 'validatorless-range-probe',
        playablePrefixPreserved: true,
        diagnostics: <String, Object?>{
          'resumeProbeStart': probeStart,
          'resumeProbeBytes': probeBytes,
          'resumeProbeStatusCode': response.statusCode,
          'resumeProbeAccepted': true,
          'duplicatePrefixBytes': duplicatePrefixBytes,
        },
      );
    } else if (fullBodyCatchup) {
      var duplicatePrefixBytes = 0;
      try {
        catchupRemainder = await _verifyFullBodyPrefix(
          iterator: iterator,
          preservedLength: preservedLength,
          expectedChecksum: session.artifact.checksum,
          expectedTotalLength: response.totalLength,
          cancel: cancel,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
          },
        );
      } catch (error) {
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup-aborted',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'duplicatePrefixBytes': duplicatePrefixBytes,
          },
        );
        await iterator.cancel();
        if (session.hasWriter) {
          await session.fail(writer, error);
        }
        rethrow;
      }
      session.recordResume(
        restarted: false,
        strategy: 'full-body-prefix-catchup',
        playablePrefixPreserved: true,
        diagnostics: <String, Object?>{
          'duplicatePrefixBytes': duplicatePrefixBytes,
        },
      );
    }

    await session.bindResponse(
      validators: response.validators,
      totalLength: response.totalLength,
    );
    final pending = BytesBuilder(copy: false);
    if (catchupRemainder.isNotEmpty) {
      pending.add(catchupRemainder);
    }
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


  Future<List<int>> _verifyArtifactOverlap({
    required StreamIterator<List<int>> iterator,
    required int probeStart,
    required int preservedLength,
    required void Function(int duplicateBytes) onDuplicateBytes,
    CancelToken? cancel,
  }) async {
    final expectedLength = preservedLength - probeStart;
    if (expectedLength <= 0 || expectedLength > _validatorlessResumeProbeBytes) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'validatorless resume probe has an invalid overlap range',
      );
    }
    final expectedBuilder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks(
      chunkSize: _validatorlessResumeProbeBytes,
      start: probeStart,
      endExclusive: preservedLength,
    )) {
      expectedBuilder.add(chunk);
    }
    final expected = expectedBuilder.takeBytes();
    if (expected.length != expectedLength) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'existing playable partial changed during resume probe',
      );
    }

    var matched = 0;
    while (matched < expected.length) {
      final available = await _moveNext(iterator, cancel);
      if (!available) {
        throw const Failure(
          code: ErrorCode.resumeRejected,
          message: 'range response ended before the overlap boundary',
        );
      }
      final chunk = iterator.current;
      if (chunk.isEmpty) {
        continue;
      }
      final remaining = expected.length - matched;
      final take = chunk.length < remaining ? chunk.length : remaining;
      for (var index = 0; index < take; index++) {
        if (chunk[index] != expected[matched + index]) {
          throw const Failure(
            code: ErrorCode.resumeRejected,
            message: 'range overlap differs from the existing playable partial',
          );
        }
      }
      matched += take;
      onDuplicateBytes(matched);
      if (matched == expected.length) {
        return take == chunk.length
            ? const <int>[]
            : chunk.sublist(take);
      }
      await Future<void>.delayed(Duration.zero);
    }
    return const <int>[];
  }

  Future<List<int>> _verifyFullBodyPrefix({
    required StreamIterator<List<int>> iterator,
    required int preservedLength,
    required String expectedChecksum,
    required int? expectedTotalLength,
    required void Function(int duplicateBytes) onDuplicateBytes,
    CancelToken? cancel,
  }) async {
    if (preservedLength <= 0) {
      return const <int>[];
    }
    if (expectedChecksum.isEmpty) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'partial checksum unavailable; preserved the existing partial',
      );
    }
    if (expectedTotalLength != null && expectedTotalLength < preservedLength) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'full response is shorter than the existing partial',
      );
    }

    final checksum = Crc32();
    var remaining = preservedLength;
    var consumed = 0;
    while (remaining > 0) {
      final available = await _moveNext(iterator, cancel);
      if (!available) {
        throw const Failure(
          code: ErrorCode.resumeRejected,
          message: 'full response ended before the existing partial boundary',
        );
      }
      final chunk = iterator.current;
      if (chunk.isEmpty) {
        continue;
      }
      final take = chunk.length < remaining ? chunk.length : remaining;
      checksum.add(take == chunk.length ? chunk : chunk.sublist(0, take));
      remaining -= take;
      consumed += take;
      onDuplicateBytes(consumed);
      if (remaining == 0) {
        if (checksum.hex != expectedChecksum) {
          throw const Failure(
            code: ErrorCode.resumeRejected,
            message:
                'full response prefix differs from the existing playable partial',
          );
        }
        return take == chunk.length
            ? const <int>[]
            : chunk.sublist(take);
      }
      await Future<void>.delayed(Duration.zero);
    }
    return const <int>[];
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

  Future<ByteResponse> _openRange(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    final range = ByteRange(start: start);
    if (controlled != null) {
      return controlled.openControlled(
        session.id.canonicalUri,
        range: range,
        control: cancel,
      );
    }
    return transport.open(
      session.id.canonicalUri,
      range: range,
    );
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
