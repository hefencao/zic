import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';
import 'package:transport/transport.dart';

void main() {
  for (final selfBounded in <bool>[true, false]) {
    for (final lateResponse in <bool>[false, true]) {
      test('cancelled ${selfBounded ? 'self-bounded' : 'handed-off'} open '
          'holds NetLane until ${lateResponse ? 'response discard' : 'exit'}', () async {
        final root = await Directory.systemTemp.createTemp('open_retirement_');
        final session = DownloadSession(
          id: DownloadId(
            content: const ContentId(sourceId: 'source', comicId: 'comic',
              chapterId: 'chapter', pageId: 'page'),
            sourceRevision: 'r1', canonicalUri: Uri.parse('runtime://page'),
          ),
          artifact: Artifact(partialPath: '${root.path}/partial/page',
            finalPath: '${root.path}/cache/page'),
          clock: FakeMonoClock(),
        );
        final transport = _DrainingOpenTransport(selfBounded, lateResponse);
        final errors = <Object>[];
        final lane = NetLane(maxActive: 1,
          onError: (_, error, _) => errors.add(error));
        var followerStarted = false;
        var retired = false;
        lane.submit(key: 'opening', priority: 900, task: (token) async {
          await DownloadJob(transport: transport, session: session,
            readStallTimeout: const Duration(seconds: 1)).run(cancel: token);
        });
        try {
          await transport.entered.future.timeout(const Duration(seconds: 1));
          lane.cancel('opening');
          await transport.cancelled.future.timeout(const Duration(seconds: 1));
          unawaited(lane.idleKeys(<String>['opening']).then((_) => retired = true));
          lane.submit(key: 'follower', priority: 900, task: (_) async {
            followerStarted = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(lane.running, 1, reason: 'cancel is a signal, not physical exit');
          expect(lane.transportLeases, 1);
          expect(retired, isFalse);
          expect(followerStarted, isFalse);

          transport.exit.complete();
          if (lateResponse) {
            await transport.discardStarted.future.timeout(const Duration(seconds: 1));
            expect(lane.running, 1);
            expect(retired, isFalse);
            expect(followerStarted, isFalse);
            transport.discardExit.complete();
          }
          await lane.idle().timeout(const Duration(seconds: 1));
          expect(retired, isTrue);
          expect(followerStarted, isTrue);
          expect(errors, hasLength(1));
          expect(errors.single, isA<Failure>().having(
            (error) => error.code, 'code', ErrorCode.cancelled));
          expect(session.state, DownloadState.idle);
          expect(session.hasWriter, isFalse);
        } finally {
          if (!transport.exit.isCompleted) transport.exit.complete();
          if (!transport.discardExit.isCompleted) transport.discardExit.complete();
          await lane.idle().timeout(const Duration(seconds: 2));
          await root.delete(recursive: true);
        }
      });
    }
  }
}

final class _DrainingOpenTransport
    implements ControlledTransport, SelfBoundedOpenTransport {
  _DrainingOpenTransport(this.selfBounded, this.lateResponse);
  final bool selfBounded;
  final bool lateResponse;
  final entered = Completer<void>();
  final cancelled = Completer<void>();
  final exit = Completer<void>();
  final discardStarted = Completer<void>();
  final discardExit = Completer<void>();

  @override
  bool selfBoundsOpen(Uri uri) => selfBounded;

  @override
  Future<ByteResponse> open(Uri uri, {ByteRange? range, Validators? validators}) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(Uri uri, {ByteRange? range,
      Validators? validators, TaskControl? control}) async {
    if (!selfBounded && control is OpenPhaseReportingTaskControl) {
      control.markOpenSelfBounded();
    }
    unawaited(control!.whenCancelled.then((_) => cancelled.complete()));
    entered.complete();
    await exit.future;
    if (!lateResponse) control.throwIfCancelled();
    return ByteResponse(bytes: const Stream<List<int>>.empty(),
      statusCode: HttpStatus.ok, rangeStart: 0, totalLength: 0,
      onDiscard: () async {
        discardStarted.complete();
        await discardExit.future;
      });
  }
}
