import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:transport/transport.dart';

import 'download_session.dart';
import 'net_lane.dart';
import 'source_progress.dart';
import 'webp_decode_prefix_hints.dart';
import 'webp_frame_prefix_tracker.dart';

const int _validatorlessResumeProbeBytes = 64 * 1024;

typedef FullBodyCatchupPermission = bool Function(int preservedLength);

final class DownloadCatchupDeferred implements Exception {
  const DownloadCatchupDeferred({required this.preservedLength});

  final int preservedLength;
}


final class DownloadJob {
  const DownloadJob({
    required this.transport,
    required this.session,
    this.requestUri,
    this.allowFullBodyCatchup,
    this.attachLegacyDemand = true,
    this.publishAttemptFailures = true,
    this.readStallTimeout = defaultReadStallTimeout,
  });

  /// Bounds every network body read and any transport open that does not
  /// prove its own finite lower-level deadline. A self-bounded open may use a
  /// longer source/runtime deadline, but body inactivity always keeps this
  /// watchdog so a dead response cannot hold an admitted task indefinitely.
  static const Duration defaultReadStallTimeout = Duration(seconds: 6);

  final Transport transport;
  final DownloadSession session;
  final Duration readStallTimeout;

  /// Whether this job publishes one transport attempt failure as terminal
  /// session state. Composition-owned transfers disable this so the physical
  /// owner can exhaust its retry policy before consumers observe `failed`.
  final bool publishAttemptFailures;

  /// Exact source request identity selected by the active consumer.
  ///
  /// The physical [DownloadSession] may be anchored to a different, directly
  /// verified equivalent [DownloadId]. Physical artifact/writer/resume state
  /// stays on [session], while transport opens MUST use this exact provider URI.
  /// Legacy callers default to the session anchor URI.
  final Uri? requestUri;

  Uri get _requestUri => requestUri ?? session.id.canonicalUri;

  final FullBodyCatchupPermission? allowFullBodyCatchup;
  final bool attachLegacyDemand;

  Future<DownloadSnapshot> run({
    String? expectedChecksum,
    CancelToken? cancel,
  }) async {
    final lease = session.beginRun();
    try {
      cancel?.throwIfCancelled();
      await _run(
        expectedChecksum: expectedChecksum,
        cancel: cancel,
        runLease: lease,
      );
    } on Object catch (error) {
      // The body/writer path owns its own partial cleanup. Before a writer is
      // acquired, however, setup failures (including open cancellation) can
      // otherwise leave queue()'s state visible forever. Return a cancelled
      // attempt to the idle/resumable state, and publish non-cancellation
      // setup failures as terminal for this attempt. Preserve the original
      // error if this best-effort lifecycle publication also fails.
      if (session.isCurrentRun(lease) &&
          session.state == DownloadState.queued &&
          !session.hasWriter) {
        try {
          final cancelled = cancel?.cancelled == true ||
              (error is Failure && error.code == ErrorCode.cancelled);
          if (cancelled || !publishAttemptFailures) {
            session.deferNetwork(
              reason: cancelled
                  ? 'download-attempt-cancelled'
                  : 'download-attempt-failed-owner-managed',
              expectedRun: lease,
            );
          } else {
            await session.failWithoutWriter(error);
          }
        } on Object {
          // The attempt error remains authoritative; the owner will recover a
          // session whose lifecycle publication could not be completed.
        }
      }
      rethrow;
    } finally {
      session.endNetworkAttemptProgress(expectedRun: lease);
      session.endRun(lease);
    }
    return session.snapshot;
  }

  static Future<bool> completeWithoutTransport({
    required DownloadSession session,
    String? expectedChecksum,
    TaskControl? control,
    RunLease? expectedRun,
    bool verifyPromotedChecksum = true,
  }) async {
    control?.throwIfCancelled();
    if (session.state == DownloadState.promoted) {
      // An in-memory promoted state is not, by itself, a proof that the
      // persisted final file is still the bytes that were sealed. Resident
      // bodies have no local Artifact to rehash; persisted promotions must
      // re-enter restore so the ready sidecar and same-length file are
      // verified before a later run reuses them.
      if (session.residentBodyBacked) return true;
      final restored = await session.restore(
        verifyPromotedChecksum: verifyPromotedChecksum,
        expectedRun: expectedRun,
        control: control,
      );
      control?.throwIfCancelled();
      return restored.state == DownloadState.promoted;
    }
    if (session.committedLength <= 0 ||
        session.totalLength != session.committedLength ||
        session.artifact.state != ArtifactState.partial) {
      return false;
    }
    control?.throwIfCancelled();
    final writer = session.acquireWriter(expectedRun: expectedRun);
    try {
      await session.seal(
        writer,
        expectedLength: session.totalLength,
        expectedChecksum: expectedChecksum,
      );
      // Once seal has committed the artifact and cleared the writer, a
      // cancellation must not strand the session in DownloadState.sealed.
      // Finish the short seal-to-promote transaction, then report a late
      // cancellation from the already terminal promoted state.
      await session.promote(expectedRun: expectedRun);
      control?.throwIfCancelled();
      return true;
    } on Object catch (error) {
      // Seal/checksum failures can occur before the writer is cleared. Use
      // the same writer terminal path as a network attempt so no sink or
      // lease survives a failed transport-less completion.
      try {
        await session.fail(writer, error);
      } on Object {
        // Preserve the original completion error; the session will be
        // reclaimed by its owner if the secondary cleanup also fails.
      }
      rethrow;
    }
  }

  Future<void> _run({
    String? expectedChecksum,
    CancelToken? cancel,
    required RunLease runLease,
  }) async {
    cancel?.throwIfCancelled();
    session.requireRun(runLease);
    if (await completeWithoutTransport(
      session: session,
      expectedChecksum: expectedChecksum,
      control: cancel,
      expectedRun: runLease,
    )) {
      session.requireRun(runLease);
      return;
    }
    await session.restore(
      verifyPromotedChecksum: false,
      expectedRun: runLease,
      control: cancel,
    );
    session.requireRun(runLease);
    cancel?.throwIfCancelled();
    session.requireRun(runLease);
    if (session.state == DownloadState.promoted) {
      return;
    }
    if (await completeWithoutTransport(
      session: session,
      expectedChecksum: expectedChecksum,
      control: cancel,
      expectedRun: runLease,
    )) {
      session.requireRun(runLease);
      return;
    }
    session.requireRun(runLease);

    if (attachLegacyDemand) {
      session.attach();
    }
    session.queue();

    final preservedLength = session.committedLength;
    final preservedTotalLength = session.totalLength;
    final resumeValidators = session.resumeValidatorsFor(_requestUri);
    final providerValidatorMismatch = preservedLength > 0 &&
        session.hasValidatorsForOtherRequest(_requestUri);
    var start = preservedLength;
    var fullBodyCatchup = false;
    var validatorlessRangeProbe = false;
    var probeStart = 0;
    var probeBytes = 0;
    ByteResponse response;
    _DownloadResponseLifetime? responseOwner;
    Future<ByteResponse> openResponse(
      Future<ByteResponse> Function() open,
    ) async {
      final opened = await _openForRun(
        open,
        runLease: runLease,
        cancel: cancel,
      );
      responseOwner = _DownloadResponseLifetime(opened, control: cancel);
      return opened;
    }
    cancel?.throwIfCancelled();
    try {
    if (start > 0 && !resumeValidators.canResume) {
      if (preservedTotalLength != null &&
          preservedTotalLength >= start) {
        probeBytes = start < _validatorlessResumeProbeBytes
            ? start
            : _validatorlessResumeProbeBytes;
        probeStart = start - probeBytes;
        response = await openResponse(
          () => _openRange(probeStart, cancel),
        );
        await _discardIfCancelledForRun(
          cancel,
          response,
          runLease: runLease,
        );
        final usableProbe = response.isPartial &&
            response.rangeStart == probeStart &&
            response.totalLength == preservedTotalLength;
        if (usableProbe) {
          validatorlessRangeProbe = true;
        } else if (response.statusCode == 200 && response.rangeStart == 0) {
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            runLease: runLease,
            cancel: cancel,
            response: response,
            responseOwner: responseOwner,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': response.statusCode,
              'resumeProbeAccepted': false,
              'fullBodyResponseReused': true,
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
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
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
        } else {
          final probeStatusCode = response.statusCode;
          await responseOwner!.discard();
          cancel?.throwIfCancelled();
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            runLease: runLease,
            cancel: cancel,
            diagnostics: <String, Object?>{
              'resumeProbeStart': probeStart,
              'resumeProbeBytes': probeBytes,
              'resumeProbeStatusCode': probeStatusCode,
              'resumeProbeAccepted': false,
            },
          );
          response = await openResponse(
            () => _open(0, cancel),
          );
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
              if (providerValidatorMismatch) 'providerValidatorMismatch': true,
            },
          );
        }
      } else {
        await _deferCostlyFullBodyCatchupIfNeeded(
          preservedLength: preservedLength,
          runLease: runLease,
          cancel: cancel,
          diagnostics: <String, Object?>{
            'resumeProbeAttempted': false,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        response = await openResponse(
          () => _open(0, cancel),
        );
        fullBodyCatchup = true;
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'resumeProbeAttempted': false,
            'duplicatePrefixBytes': 0,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
      }
    } else {
      response = await openResponse(
        () => _open(start, cancel),
      );
      await _discardIfCancelledForRun(
        cancel,
        response,
        runLease: runLease,
      );
      if (start > 0 &&
          response.disposition == ByteResponseDisposition.durableImmutable) {
        if (response.statusCode == 200 && response.rangeStart == 0) {
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            runLease: runLease,
            cancel: cancel,
            response: response,
            responseOwner: responseOwner,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
              'fullBodyResponseReused': true,
            },
          );
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
          await responseOwner!.discard();
          cancel?.throwIfCancelled();
          await _deferCostlyFullBodyCatchupIfNeeded(
            preservedLength: preservedLength,
            runLease: runLease,
            cancel: cancel,
            diagnostics: const <String, Object?>{
              'strongRangeRejected': true,
            },
          );
          response = await openResponse(
            () => _open(0, cancel),
          );
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
            expectedValidators: resumeValidators,
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
            await _deferCostlyFullBodyCatchupIfNeeded(
              preservedLength: preservedLength,
              runLease: runLease,
              cancel: cancel,
              response: response,
              responseOwner: responseOwner,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
                'fullBodyResponseReused': true,
              },
            );
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
            await responseOwner!.discard();
            cancel?.throwIfCancelled();
            await _deferCostlyFullBodyCatchupIfNeeded(
              preservedLength: preservedLength,
              runLease: runLease,
              cancel: cancel,
              diagnostics: const <String, Object?>{
                'strongRangeRejected': true,
              },
            );
            response = await openResponse(
              () => _open(0, cancel),
            );
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
    await _discardIfCancelledForRun(
      cancel,
      response,
      runLease: runLease,
    );

    if ((start == 0 || fullBodyCatchup) && response.rangeStart != 0) {
      await responseOwner!.discard();
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'full response did not start at offset zero',
      );
    }

    if (start == 0 && response.totalLength == 0) {
      await responseOwner!.discard();
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'image response body is empty',
      );
    }
    } catch (error) {
      await _discardAfterAbort(responseOwner?.discard);
      rethrow;
    }

    final responseLifetime = responseOwner!;
    try {
      session.beginNetworkAttemptProgress(
        response.rangeStart,
        expectedRun: runLease,
      );
    } on Object {
      await _discardAfterAbort(responseLifetime.discard);
      rethrow;
    }
    var networkCursor = response.rangeStart;
    final _ResponseReadGate? flowGate =
        response.flowControl != ByteResponseFlowControl.none &&
                response.bodyAuthority == ByteResponseBodyAuthority.source
            ? _ResponseReadGate(
                session: session,
                cancel: cancel,
                runLease: runLease,
                capability: response.flowControl,
                rangeSupported: response.rangeSupported,
              )
            : null;

    if (start == 0 &&
        response.disposition == ByteResponseDisposition.durableImmutable &&
        response.totalLength != null) {
      // A durable artifact-cache body is local replay, not network/source body
      // traffic. Once response authority is known, release NetLane's network
      // body-read permit before consuming the local stream; the existing
      // ArtifactCacheReadScheduler remains the sole body-bandwidth owner.
      if (response.bodyAuthority == ByteResponseBodyAuthority.artifactCache) {
        cancel?.releaseResponseReadPermit(responseRetained: false);
        session.recordTransportReadPermit(
          action: 'released',
          reason: 'durable-artifact-local-body',
          responseReadPermitHeld: false,
          demanded: cancel?.demanded,
          bodyAuthority: response.bodyAuthority.name,
        );
      }
      var residentOffset = 0;
      final residentIterator = StreamIterator<List<int>>(response.bytes);
      try {
        session.beginResidentImmutableIngress(
          validators: response.validators,
          totalLength: response.totalLength!,
          validatorRequestUri: _requestUri,
          bodyAuthority: response.bodyAuthority,
        );
        while (true) {
          final available = await _moveNext(
            residentIterator,
            cancel,
            onAbort: responseLifetime.discard,
          );
          session.requireRun(runLease);
          if (!available) break;
          final chunk = residentIterator.current;
          if (chunk.isEmpty) continue;
          session.appendResidentImmutableIngress(residentOffset, chunk);
          residentOffset += chunk.length;
          networkCursor += chunk.length;
          session.advanceNetworkAttemptProgress(
            networkCursor,
            expectedRun: runLease,
          );
          await Future<void>.value();
          session.requireRun(runLease);
        }
        session.sealResidentImmutableIngress();
        return;
      } catch (error) {
        await _cancelIteratorAndDiscard(
          residentIterator,
          responseLifetime.discard,
        );
        if (session.isCurrentRun(runLease)) {
          // The resident body came from an external durable artifact-cache
          // authority. Reset only this ephemeral transfer projection; deleting
          // the session cache record here could erase a persistent replica
          // binding whose failure is merely access-related and recoverable.
          await session.reset(removeCacheRecord: false);
        }
        rethrow;
      } finally {
        try {
          await residentIterator.cancel();
        } on Object {
          // The response is already fully consumed on success. A best-effort
          // iterator close must not turn a promoted resident body into a
          // failed download; error paths already perform discard cleanup.
        }
      }
    }

    session.requireRun(runLease);
    cancel?.beginRestartCost();

    late final WriterLease writer;
    try {
      writer = session.acquireWriter(expectedRun: runLease);
    } catch (error) {
      await _discardAfterAbort(responseLifetime.discard);
      rethrow;
    }
    var offset = session.committedLength;
    final iterator = StreamIterator<List<int>>(response.bytes);
    List<int> catchupRemainder = const <int>[];
    var restartCostBytes = 0;
    if (validatorlessRangeProbe &&
        response.statusCode == 206 &&
        response.rangeStart == probeStart) {
      var duplicatePrefixBytes = 0;
      try {
        catchupRemainder = await _verifyArtifactOverlap(
          iterator: iterator,
          probeStart: probeStart,
          preservedLength: preservedLength,
          cancel: cancel,
          flowGate: flowGate,
          networkCursor: () => networkCursor,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
            networkCursor = probeStart + value;
            session.advanceNetworkAttemptProgress(
              networkCursor,
              expectedRun: runLease,
            );
          },
          onAbort: responseLifetime.discard,
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
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        await _cancelIteratorAndDiscard(
          iterator,
          responseLifetime.discard,
        );
        await _finishWriterAfterAttemptError(
          writer,
          error,
          runLease: runLease,
          cancelled: cancel?.cancelled == true,
        );
        rethrow;
      }
      networkCursor = probeStart + probeBytes + catchupRemainder.length;
      session.advanceNetworkAttemptProgress(
        networkCursor,
        force: true,
        expectedRun: runLease,
      );
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
          if (providerValidatorMismatch) 'providerValidatorMismatch': true,
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
          flowGate: flowGate,
          networkCursor: () => networkCursor,
          onDuplicateBytes: (value) {
            duplicatePrefixBytes = value;
            restartCostBytes = value;
            networkCursor = value;
            session.advanceNetworkAttemptProgress(
              networkCursor,
              expectedRun: runLease,
            );
            cancel?.recordRestartCostBytes(restartCostBytes);
          },
          onAbort: responseLifetime.discard,
        );
      } catch (error) {
        session.recordResume(
          restarted: true,
          strategy: 'full-body-prefix-catchup-aborted',
          playablePrefixPreserved: true,
          diagnostics: <String, Object?>{
            'duplicatePrefixBytes': duplicatePrefixBytes,
            if (providerValidatorMismatch) 'providerValidatorMismatch': true,
          },
        );
        await _cancelIteratorAndDiscard(
          iterator,
          responseLifetime.discard,
        );
        await _finishWriterAfterAttemptError(
          writer,
          error,
          runLease: runLease,
          cancelled: cancel?.cancelled == true,
        );
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
      if (catchupRemainder.isNotEmpty) {
        restartCostBytes += catchupRemainder.length;
        networkCursor = preservedLength + catchupRemainder.length;
        session.advanceNetworkAttemptProgress(
          networkCursor,
          force: true,
          expectedRun: runLease,
        );
        cancel?.recordRestartCostBytes(restartCostBytes);
      } else {
        networkCursor = preservedLength;
        session.advanceNetworkAttemptProgress(
          networkCursor,
          force: true,
          expectedRun: runLease,
        );
      }
    }

    final pending = BytesBuilder(copy: false);
    if (catchupRemainder.isNotEmpty) {
      pending.add(catchupRemainder);
    }
    var flushTarget = 16 * 1024;
    Future<void> flushPending() async {
      if (pending.length == 0) return;
      final bytes = pending.takeBytes();
      await session.append(writer, offset, bytes);
      session.requireRun(runLease);
      offset += bytes.length;
      flushTarget = sourceProgressQuantumBytes;
    }
    try {
      if (catchupRemainder.isNotEmpty) {
        flowGate?.addAuthoritativeBytes(catchupRemainder);
      }
      await session.bindResponse(
        validators: response.validators,
        totalLength: response.totalLength,
        validatorRequestUri: _requestUri,
      );
      session.requireRun(runLease);
      while (true) {
        if (flowGate != null &&
            (flowGate.needsArtifactSynchronization ||
                flowGate.blocked ||
                flowGate.demandPaused)) {
          await flushPending();
        }
        final available = await _moveNext(
          iterator,
          cancel,
          flowGate: flowGate,
          networkCursor: networkCursor,
          onAbort: responseLifetime.discard,
        );
        session.requireRun(runLease);
        if (!available) break;
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        flowGate?.addAuthoritativeBytes(chunk);
        if (fullBodyCatchup) {
          restartCostBytes += chunk.length;
          cancel?.recordRestartCostBytes(restartCostBytes);
        }
        networkCursor += chunk.length;
        session.advanceNetworkAttemptProgress(
          networkCursor,
          expectedRun: runLease,
        );
        pending.add(chunk);
        if (pending.length >= flushTarget || offset == 0) {
          await flushPending();
          session.requireRun(runLease);
        }
      }
      await flushPending();
      session.requireRun(runLease);
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
      session.requireRun(runLease);
      await session.promote(expectedRun: runLease);
    } catch (error) {
      // Preserve bytes already delivered by the transport so resume semantics
      // remain independent of the transport's arbitrary chunk size.
      try {
        await flushPending();
      } on Object {
        // The original failure remains authoritative; session.fail closes the
        // writer and records the recoverable partial state below.
      }
      await _cancelIteratorAndDiscard(
        iterator,
        responseLifetime.discard,
      );
      await _finishWriterAfterAttemptError(
        writer,
        error,
        runLease: runLease,
        cancelled: cancel?.cancelled == true,
      );
      rethrow;
    } finally {
      // Reaching the end of the body normally closes the stream subscription,
      // but make that lifetime boundary explicit for transports whose stream
      // owns a native response handle. Cancellation/error cleanup above is
      // idempotent, so a second close is harmless and best-effort.
      try {
        await iterator.cancel();
      } on Object {
        // Preserve the download result; the response discard path owns error
        // reporting for aborted attempts.
      }
    }
  }

  Future<void> _finishWriterAfterAttemptError(
    WriterLease writer,
    Object error, {
    required RunLease runLease,
    bool cancelled = false,
  }) async {
    if (!session.hasWriter) return;
    try {
      session.requireRun(runLease);
    } on Failure catch (stale) {
      if (stale.code == ErrorCode.staleRun) return;
      rethrow;
    }
    try {
      if (cancelled ||
          !publishAttemptFailures ||
          (error is Failure && error.code == ErrorCode.cancelled)) {
        // Scheduler/lifecycle cancellation and owner-managed attempt failure
        // end only this transport attempt. Preserve the authoritative partial
        // as resumable; the physical owner alone decides whether retries are
        // exhausted and when consumers may observe terminal `failed`.
        await session.pause(writer);
        return;
      }
      await session.fail(writer, error);
    } on Failure catch (failure) {
      // A concurrent reset owns the writer cleanup and invalidates this run.
      // Do not replace the transport error with a stale cleanup error.
      if (failure.code == ErrorCode.staleRun &&
          !session.isCurrentRun(runLease)) {
        return;
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
    _ResponseReadGate? flowGate,
    int Function()? networkCursor,
    Future<void> Function()? onAbort,
  }) async {
    final expectedLength = preservedLength - probeStart;
    if (expectedLength <= 0 || expectedLength > _validatorlessResumeProbeBytes) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'validatorless resume probe has an invalid overlap range',
      );
    }
    final expected = await _readExistingArtifact(
      start: probeStart,
      endExclusive: preservedLength,
      cancel: cancel,
    );
    if (expected.length != expectedLength) {
      throw const Failure(
        code: ErrorCode.resumeRejected,
        message: 'existing playable partial changed during resume probe',
      );
    }

    var matched = 0;
    while (matched < expected.length) {
      final available = await _moveNext(
        iterator,
        cancel,
        flowGate: flowGate,
        networkCursor: networkCursor?.call() ?? 0,
        onAbort: onAbort,
      );
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
      await Future<void>.value();
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
    _ResponseReadGate? flowGate,
    int Function()? networkCursor,
    Future<void> Function()? onAbort,
  }) async {
    if (preservedLength <= 0) {
      return const <int>[];
    }
    var targetChecksum = expectedChecksum;
    if (targetChecksum.isEmpty) {
      final preserved = await _readExistingArtifact(
        start: 0,
        endExclusive: preservedLength,
        cancel: cancel,
      );
      final diskCrc = Crc32()..add(preserved);
      targetChecksum = diskCrc.hex;
    }
    if (targetChecksum.isEmpty) {
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
      final available = await _moveNext(
        iterator,
        cancel,
        flowGate: flowGate,
        networkCursor: networkCursor?.call() ?? 0,
        onAbort: onAbort,
      );
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
        if (checksum.hex != targetChecksum) {
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
      await Future<void>.value();
    }
    return const <int>[];
  }


  Future<Uint8List> _readExistingArtifact({
    required int start,
    required int endExclusive,
    CancelToken? cancel,
  }) async {
    final iterator = StreamIterator<List<int>>(
      session.artifact.readChunks(
        start: start,
        endExclusive: endExclusive,
      ),
    );
    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        bool available;
        if (cancel == null) {
          available = await iterator.moveNext();
        } else {
          cancel.throwIfCancelled();
          try {
            available = await Future.any<bool>(<Future<bool>>[
              iterator.moveNext(),
              cancel.whenCancelled.then<bool>((_) {
                throw const Failure(
                  code: ErrorCode.cancelled,
                  message: 'existing partial read was cancelled',
                );
              }),
            ]);
          } catch (error, stackTrace) {
            if (cancel.cancelled) cancel.throwIfCancelled();
            throw Error.throwWithStackTrace(error, stackTrace);
          }
        }
        if (!available) break;
        cancel?.throwIfCancelled();
        builder.add(iterator.current);
      }
    } finally {
      try {
        await iterator.cancel();
      } on Object {
        // Preserve the body/cancellation failure; the iterator's generator
        // still receives its best-effort close request.
      }
    }
    return builder.takeBytes();
  }

  Future<void> _deferCostlyFullBodyCatchupIfNeeded({
    required int preservedLength,
    required RunLease runLease,
    CancelToken? cancel,
    ByteResponse? response,
    _DownloadResponseLifetime? responseOwner,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) async {
    final allowed = allowFullBodyCatchup?.call(preservedLength) ?? true;
    if (allowed) {
      return;
    }
    if (response != null) {
      await (responseOwner?.discard() ?? response.discard(control: cancel));
    }
    session.requireRun(runLease);
    session.recordResume(
      restarted: true,
      strategy: 'full-body-prefix-catchup-deferred',
      playablePrefixPreserved: true,
      diagnostics: <String, Object?>{
        'deferredPrefixBytes': preservedLength,
        if (cancel != null) 'deferredPriority': cancel.priority,
        'duplicatePrefixBytes': 0,
        ...diagnostics,
      },
    );
    session.deferNetwork(reason: 'costly-full-body-catchup');
    throw DownloadCatchupDeferred(preservedLength: preservedLength);
  }

  Future<bool> _moveNext(
    StreamIterator<List<int>> iterator,
    CancelToken? cancel, {
    _ResponseReadGate? flowGate,
    int networkCursor = 0,
    Future<void> Function()? onAbort,
  }) async {
    if (flowGate != null) {
      await flowGate.waitBeforeRead(networkCursor: networkCursor);
    }
    if (cancel == null) {
      return _moveNextWithStallWatchdog(iterator, onAbort: onAbort);
    }
    cancel.throwIfCancelled();
    final Object result;
    try {
      result = await Future.any<Object>(<Future<Object>>[
        _moveNextWithStallWatchdog(iterator, onAbort: onAbort)
            .then<Object>(_NextChunk.new),
        cancel.whenCancelled.then<Object>((_) => const _DownloadCancelled()),
      ]);
    } catch (error, stackTrace) {
      // If the body and cancellation complete in the same turn, cancellation
      // remains the owner-visible outcome. The caller's attempt cleanup still
      // cancels/discards the iterator, while this conversion prevents a late
      // body exception from masking the scheduler cancellation.
      if (cancel.cancelled) cancel.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
    if (result is _DownloadCancelled) {
      await _cancelIteratorAndDiscard(iterator, onAbort);
      cancel.throwIfCancelled();
    }
    return (result as _NextChunk).available;
  }

  /// One body read, raced against the read-stall watchdog. The watchdog only
  /// covers the read itself — flow-control parking happens before it in
  /// [waitBeforeRead] and may legitimately wait.
  Future<bool> _moveNextWithStallWatchdog(
    StreamIterator<List<int>> iterator, {
    Future<void> Function()? onAbort,
  }) {
    if (readStallTimeout <= Duration.zero) {
      return iterator.moveNext();
    }
    final watchdog = Completer<Never>();
    final timer = Timer(readStallTimeout, () {
      if (!watchdog.isCompleted) {
        watchdog.completeError(const Failure(
          code: ErrorCode.network,
          message: 'body read stalled: no bytes within the read stall window',
        ));
      }
    });
    return Future.any<bool>(<Future<bool>>[
      Future<bool>.sync(iterator.moveNext),
      watchdog.future,
    ]).then<bool>((available) {
      timer.cancel();
      return available;
    }, onError: (Object error, StackTrace stackTrace) async {
      timer.cancel();
      if (watchdog.isCompleted) {
        // The watchdog won the race: the read never returned. Cancel the
        // abandoned subscription before propagating so the response cannot
        // leak past the task exit.
        await _cancelIteratorAndDiscard(iterator, onAbort);
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> _cancelIteratorAndDiscard(
    StreamIterator<List<int>> iterator,
    Future<void> Function()? discard,
  ) async {
    try {
      await iterator.cancel();
    } on Object {
      // Iterator cancellation is best-effort cleanup. Preserve the original
      // body/cancellation/watchdog failure while still attempting response
      // discard below.
    }
    await _discardAfterAbort(discard);
  }

  Future<void> _discardAfterAbort(
    Future<void> Function()? discard,
  ) async {
    if (discard == null) return;
    try {
      await discard();
    } on Object {
      // Preserve the cancellation/watchdog/body failure that caused this
      // cleanup. A later owner retry can observe a transport-discard error if
      // the response implementation reports it independently.
    }
  }

  Future<void> _discardIfCancelled(
    CancelToken? cancel,
    ByteResponse response,
  ) async {
    if (cancel?.cancelled ?? false) {
      await _discardAfterAbort(
        () => response.discard(control: cancel),
      );
      cancel!.throwIfCancelled();
    }
  }

  Future<void> _discardIfCancelledForRun(
    CancelToken? cancel,
    ByteResponse response, {
    required RunLease runLease,
  }) async {
    await _discardIfCancelled(cancel, response);
    session.requireRun(runLease);
  }

  Future<ByteResponse> _openForRun(
    Future<ByteResponse> Function() open, {
    required RunLease runLease,
    CancelToken? cancel,
  }) async {
    final response = await open();
    try {
      session.requireRun(runLease);
    } on Object {
      await _discardAfterAbort(
        () => response.discard(control: cancel),
      );
      rethrow;
    }
    return response;
  }

  Future<ByteResponse> _openRange(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    final range = ByteRange(start: start);
    if (controlled != null) {
      return _openWithStallWatchdog(
        () => controlled.openControlled(
          _requestUri,
          range: range,
          control: cancel,
        ),
        control: cancel,
      );
    }
    return _openWithStallWatchdog(
      () => transport.open(
        _requestUri,
        range: range,
      ),
      control: cancel,
    );
  }

  Future<ByteResponse> _open(int start, CancelToken? cancel) {
    final controlled = transport is ControlledTransport
        ? transport as ControlledTransport
        : null;
    final validators = session.resumeValidatorsFor(_requestUri);
    if (start > 0 && validators.canResume) {
      if (controlled != null) {
        return _openWithStallWatchdog(
          () => controlled.openControlled(
            _requestUri,
            range: ByteRange(start: start),
            validators: validators,
            control: cancel,
          ),
          control: cancel,
        );
      }
      return _openWithStallWatchdog(
        () => transport.open(
          _requestUri,
          range: ByteRange(start: start),
          validators: validators,
        ),
        control: cancel,
      );
    }
    if (controlled != null) {
      return _openWithStallWatchdog(
        () => controlled.openControlled(
          _requestUri,
          control: cancel,
        ),
        control: cancel,
      );
    }
    return _openWithStallWatchdog(
      () => transport.open(_requestUri),
      control: cancel,
    );
  }

  /// Bounds one transport open with the same read-stall window. A suspended
  /// plugin runtime or a dead socket blocks the request **before** any body
  /// read starts, so the read watchdog alone never fires there; without this
  /// bound the admitted task sits in open() forever, keeps its NetLane task
  /// key and blocks every retry from being admitted.
  Future<ByteResponse> _openWithStallWatchdog(
    Future<ByteResponse> Function() open, {
    CancelToken? control,
  }) {
    control?.throwIfCancelled();
    control?.markResponseOpening();
    final pending = Future<ByteResponse>.sync(open);
    final openIsSelfBounded = transport is SelfBoundedOpenTransport &&
        (transport as SelfBoundedOpenTransport).selfBoundsOpen(_requestUri);
    if (readStallTimeout <= Duration.zero || openIsSelfBounded) {
      if (control == null) {
        return pending.then<ByteResponse>((response) {
          control?.markResponseOpened();
          return response;
        });
      }
      return Future.any<ByteResponse>(<Future<ByteResponse>>[
        pending,
        control.whenCancelled.then<ByteResponse>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'transport open was cancelled',
          );
        }),
      ]).then<ByteResponse>((response) {
        control.markResponseOpened();
        return response;
      }, onError: (Object error, StackTrace stackTrace) async {
        if (control.cancelled) {
          // An uncontrolled open may complete after the caller has already
          // abandoned this attempt. It still owns a response if it eventually
          // succeeds, so discard that late response rather than leaking the
          // underlying socket/stream when the watchdog is disabled.
          unawaited(
            pending.then<void>(
              (response) async {
                try {
                  await response.discard(control: control);
                } on Object {
                  // The cancellation error remains authoritative.
                }
              },
              onError: (Object _, StackTrace __) {},
            ),
          );
          control.throwIfCancelled();
        }
        throw Error.throwWithStackTrace(error, stackTrace);
      });
    }
    final watchdog = Completer<Never>();
    final timer = Timer(readStallTimeout, () {
      if (!watchdog.isCompleted) {
        watchdog.completeError(const Failure(
          code: ErrorCode.network,
          message:
              'transport open stalled: no response within the read stall window',
        ));
      }
    });
    final waits = <Future<ByteResponse>>[
      pending,
      watchdog.future,
    ];
    if (control != null) {
      waits.add(control.whenCancelled.then<ByteResponse>((_) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'transport open was cancelled',
        );
      }));
    }
    return Future.any<ByteResponse>(waits).then<ByteResponse>((response) {
      timer.cancel();
      control?.markResponseOpened();
      return response;
    }, onError: (Object error, StackTrace stackTrace) async {
      timer.cancel();
      if (watchdog.isCompleted || control?.cancelled == true) {
        // The open may still complete long after the watchdog or cancellation
        // gave up; discard the late response so the underlying request cannot
        // leak.
        unawaited(
          pending.then<void>(
            (response) async {
              try {
                await response.discard(control: control);
              } on Object {
                // The watchdog/cancellation error remains authoritative.
              }
            },
            onError: (Object _, StackTrace __) {},
          ),
        );
      }
      if (control?.cancelled == true) {
        control!.throwIfCancelled();
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    });
  }
}

final class _ResponseReadGate {
  _ResponseReadGate({
    required this.session,
    required this.cancel,
    required this.runLease,
    required this.capability,
    required this.rangeSupported,
  }) : _authoritativeCatchupFloor = session.committedLength;

  final DownloadSession session;
  final CancelToken? cancel;
  final RunLease runLease;
  final ByteResponseFlowControl capability;
  final bool rangeSupported;
  final int _authoritativeCatchupFloor;
  static const Duration _flowEvidencePollInterval = Duration(milliseconds: 100);
  WebpFramePrefixTracker? _tracker;
  bool _initializing = false;
  bool _paused = false;

  bool get needsArtifactSynchronization =>
      (cancel?.flowTargetFrames ?? 0) > 0 && _tracker == null;

  bool get demandPaused => cancel != null && !cancel!.demanded;

  /// Structural ANMF credit only. The caller uses this to flush pending bytes
  /// so decoder-visible ingress catches up before [waitBeforeRead] evaluates
  /// the separate playable-prefix floor.
  bool get blocked {
    final control = cancel;
    final tracker = _tracker;
    return control != null &&
        tracker != null &&
        !tracker.unsupported &&
        control.flowBlockedAt(tracker.completedFrames);
  }

  int get _playablePrefixFloorBytes => session.playableFlowPrefixFloorBytes(
        unresolvedFloorBytes: webpDecodePrefixQuantumBytesFor(session.id),
      );

  bool _shouldBlock() {
    final control = cancel;
    final tracker = _tracker;
    if (control == null || tracker == null || tracker.unsupported) return false;
    if (!control.flowBlockedAt(tracker.completedFrames)) return false;
    // ANMF boundaries only prove encoded structure. Speculative flow may stop
    // only after the authoritative partial also reaches the decoder-owned
    // first-playable/need-more-data floor for this physical generation.
    return session.committedLength >= _playablePrefixFloorBytes;
  }

  Future<void> _ensureInitialized() async {
    session.requireRun(runLease);
    if (_tracker != null || _initializing) return;
    final control = cancel;
    if (control == null) return;
    _initializing = true;
    final iterator = StreamIterator<List<int>>(
      session.artifact.readChunks(
        endExclusive: session.committedLength,
      ),
    );
    try {
      final tracker = WebpFramePrefixTracker();
      while (true) {
        control.throwIfCancelled();
        final Object result;
        try {
          result = await Future.any<Object>(<Future<Object>>[
            iterator.moveNext().then<Object>((available) => available),
            control.whenCancelled.then<Object>((_) {
              throw const Failure(
                code: ErrorCode.cancelled,
                message: 'flow-control artifact read was cancelled',
              );
            }),
            control.whenDemandChanged.then<Object>(
              (_) => const _FlowDemandChanged(),
            ),
          ]);
        } catch (error, stackTrace) {
          if (control.cancelled) control.throwIfCancelled();
          throw Error.throwWithStackTrace(error, stackTrace);
        }
        session.requireRun(runLease);
        if (result is _FlowDemandChanged) return;
        final available = result as bool;
        if (!available) break;
        control.throwIfCancelled();
        // A demanded-state withdrawal is a parking transition, not task
        // cancellation. Do not finish scanning a potentially large persisted
        // prefix while still holding the response-read permit; abandon this
        // provisional tracker and let waitBeforeRead release the permit.
        if (!control.demanded || control.flowTargetFrames <= 0) return;
        session.requireRun(runLease);
        tracker.add(iterator.current);
      }
      session.requireRun(runLease);
      _tracker = tracker;
    } finally {
      try {
        await iterator.cancel();
      } on Object {
        // Preserve the body/cancellation failure that caused this local
        // replay to stop; the iterator still received its best-effort close.
      }
      _initializing = false;
    }
  }

  Future<void> waitBeforeRead({required int networkCursor}) async {
    final control = cancel;
    if (control == null) {
      session.requireRun(runLease);
      return;
    }

    while (true) {
      session.requireRun(runLease);
      control.throwIfCancelled();
      final demandParked = !control.demanded;
      var flowParked = false;
      WebpFramePrefixTracker? tracker;
      if (!demandParked && control.flowTargetFrames > 0 &&
          networkCursor >= _authoritativeCatchupFloor) {
        await _ensureInitialized();
        session.requireRun(runLease);
        // Demand withdrawal may have interrupted the provisional artifact
        // scan. Re-evaluate it after the await rather than returning to the
        // body-read path with the stale pre-scan value.
        if (!control.demanded) continue;
        tracker = _tracker;
        flowParked = tracker != null &&
            !tracker.unsupported &&
            _shouldBlock();
      }
      if (!demandParked && !flowParked) {
        if (_paused) {
          await control.acquireResponseReadPermit();
          session.requireRun(runLease);
          // Demand may have been withdrawn while the resume waiter was
          // pending. NetLane completes that waiter to wake this task, but it
          // must not let a demand reattachment race make the task continue
          // without actually holding a body-read permit.
          if (!control.demanded || !control.responseReadPermitHeld) {
            // Demand can be withdrawn after NetLane grants the resume waiter
            // but before this continuation observes that grant. Return the
            // retained response to the parked state instead of carrying the
            // body-read permit while waiting for a future reattachment.
            if (!control.demanded && control.responseReadPermitHeld) {
              control.releaseResponseReadPermit(responseRetained: true);
            }
            continue;
          }
          _paused = false;
          session.recordFlowControl(
            action: capability == ByteResponseFlowControl.streamBackpressure
                ? 'resumed'
                : 'pseudo-resumed',
            mode: capability.name,
            targetFrames: control.flowTargetFrames,
            completedFrames: tracker?.completedFrames ??
                session.networkFlowSatisfiedFrames,
            networkCursor: networkCursor,
            playablePrefixFloorBytes: _playablePrefixFloorBytes,
            responseRangeSupported: rangeSupported,
            responseRetained: true,
            responseReadPermitHeld: true,
            demanded: control.demanded,
          );
        }
        return;
      }

      tracker ??= _tracker;
      final completedFrames = tracker?.completedFrames ??
          session.networkFlowSatisfiedFrames;
      if (flowParked && completedFrames > 0) {
        session.observeNetworkFlowFrameProof(
          completedFrames: completedFrames,
          committedLengthAtProof: session.committedLength,
        );
      }
      if (!_paused) {
        _paused = true;
        session.recordFlowControl(
          action: capability == ByteResponseFlowControl.streamBackpressure
              ? 'paused'
              : 'pseudo-paused',
          mode: capability.name,
          targetFrames: control.flowTargetFrames,
          completedFrames: completedFrames,
          networkCursor: networkCursor,
          playablePrefixFloorBytes: _playablePrefixFloorBytes,
          responseRangeSupported: rangeSupported,
          retentionReason: demandParked
              ? 'no-consumer-demand'
              : 'bounded-flow-credit',
          responseRetained: true,
          responseReadPermitHeld: true,
          demanded: control.demanded,
        );
        control.releaseResponseReadPermit();
        session.recordFlowControl(
          action: capability == ByteResponseFlowControl.streamBackpressure
              ? 'response-parked'
              : 'pseudo-parked',
          mode: capability.name,
          targetFrames: control.flowTargetFrames,
          completedFrames: completedFrames,
          networkCursor: networkCursor,
          playablePrefixFloorBytes: _playablePrefixFloorBytes,
          responseRangeSupported: rangeSupported,
          retentionReason: demandParked
              ? 'no-consumer-demand'
              : 'bounded-flow-credit',
          responseRetained: true,
          responseReadPermitHeld: false,
          demanded: control.demanded,
        );
      }

      // The StreamIterator stays alive and no body read is requested here.
      // NetLane has released only the bounded body-read permit; the physical
      // response/task remains owned by this DownloadJob. Control/evidence
      // changes are polled because decoder need-more-data can strengthen the
      // playable-prefix floor without a second scheduler owner.
      await control.waitForControlChangeOrTimeout(_flowEvidencePollInterval);
      session.requireRun(runLease);
    }
  }

  void addAuthoritativeBytes(List<int> bytes) {
    session.requireRun(runLease);
    _tracker?.add(bytes);
  }
}

final class _DownloadResponseLifetime {
  _DownloadResponseLifetime(this.response, {required this.control});

  final ByteResponse response;
  final TaskControl? control;
  Future<void>? _discardFuture;

  Future<void> discard() => _discardFuture ??=
      response.discard(control: control);
}

final class _NextChunk {
  const _NextChunk(this.available);

  final bool available;
}

final class _DownloadCancelled {
  const _DownloadCancelled();
}

final class _FlowDemandChanged {
  const _FlowDemandChanged();
}
