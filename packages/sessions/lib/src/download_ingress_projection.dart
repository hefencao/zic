import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:media/media.dart';

typedef SourceListener = void Function(IngressSnap snapshot);

/// Reader-local projection of one physical [DownloadSession] into a native
/// encoded source.
///
/// The physical download owns artifact bytes, writer/run state and network
/// resume metadata. This projection owns only one consumer's [Ingress] and its
/// source listeners. Multiple projections may attach to the same physical
/// download without sharing decode/upload state.
final class DownloadIngressProjection {
  DownloadIngressProjection({
    required this.scopeId,
    required this.ingress,
    int? decodePrefixQuantumBytes,
    bool decoderDrivenSourceGrowth = false,
  })  : _decodePrefixQuantumBytes = decodePrefixQuantumBytes,
        _decoderDrivenSourceGrowth = decoderDrivenSourceGrowth {
    if (scopeId.isEmpty) {
      throw ArgumentError.value(scopeId, 'scopeId', 'must not be empty');
    }
  }

  final String scopeId;
  final Ingress ingress;

  /// Physical encoded-source growth quantum for incremental decode. Null keeps
  /// the logical DownloadId scheme as the fallback authority. Durable local
  /// replay sets this explicitly because its original URI may still be remote.
  int? get decodePrefixQuantumBytes => _decodePrefixQuantumBytes;
  int? _decodePrefixQuantumBytes;

  void setDecodePrefixQuantumBytes(int? value) {
    if (value != null && value <= 0) {
      throw ArgumentError.value(value, 'value', 'must be positive');
    }
    _decodePrefixQuantumBytes = value;
  }

  /// True when the current encoded prefix grows only after DecodeSession
  /// publishes explicit need-more-data evidence. An unsealed source with this
  /// contract must not hide that evidence behind partial-prefix playback.
  bool get decoderDrivenSourceGrowth => _decoderDrivenSourceGrowth;
  bool _decoderDrivenSourceGrowth;

  /// Authoritative animation evidence available from the encoded WebP prefix.
  /// Null means the prefix is not yet sufficient to classify it.
  WebpAnimationEvidence? get webpAnimationEvidence => _webpAnimationEvidence;
  WebpAnimationEvidence? _webpAnimationEvidence;
  final List<int> _webpEvidencePrefix = <int>[];

  void setDecoderDrivenSourceGrowth(bool value) {
    _decoderDrivenSourceGrowth = value;
  }

  final Set<SourceListener> _listeners = <SourceListener>{};
  bool _synchronizedReplayPending = false;
  IngressSnap? _synchronizedReplayBaseline;

  IngressSnap get snapshot {
    final current = ingress.snapshot;
    if (!_synchronizedReplayPending) return current;
    return IngressSnap(
      epoch: current.epoch,
      length: current.length,
      kind: current.kind,
      sealed: current.sealed,
      sourceReady: false,
      revision: current.revision,
      failure: current.failure,
    );
  }

  EncodedSource? get source =>
      _synchronizedReplayPending ? null : ingress.source;

  /// Checks the backing source's identity even while synchronized replay hides
  /// it from new bindings. Visibility alone does not retire an in-flight fill.
  bool isCurrentSource(EncodedSource source) => identical(ingress.source, source);

  /// Hides a late-join source while an authoritative physical prefix is being
  /// replayed into it. Decode must not bind to an intermediate source that may
  /// still need a same-epoch catch-up or rebuild before physical attachment.
  void beginSynchronizedReplay() {
    if (_synchronizedReplayPending) return;
    _synchronizedReplayBaseline = snapshot;
    _synchronizedReplayPending = true;
  }

  /// Publishes the replayed source. A late-join caller may invoke this after a
  /// decoder-usable prefix is locally replayed, then continue same-source
  /// suffix catch-up before joining the physical live fan-out. The physical
  /// owner remains responsible for proving a stable boundary before fan-out.
  void publishSynchronizedReplayPrefix() {
    if (!_synchronizedReplayPending) return;
    final before = _synchronizedReplayBaseline ?? snapshot;
    _synchronizedReplayPending = false;
    _synchronizedReplayBaseline = null;
    _notify(before, snapshot);
  }

  void finishSynchronizedReplay() {
    publishSynchronizedReplayPrefix();
  }

  void addSourceListener(
    SourceListener listener, {
    bool fireImmediately = true,
  }) {
    _listeners.add(listener);
    final current = snapshot;
    if (fireImmediately &&
        (current.sourceReady || current.failure != null)) {
      try {
        listener(current);
      } on Object {
        // Consumer observers must not break the native ingress projection.
      }
    }
  }

  void removeSourceListener(SourceListener listener) {
    _listeners.remove(listener);
  }

  void expectLength(int? length) {
    ingress.expectLength(length);
  }

  void reset(SourceEpoch epoch) {
    _resetWebpAnimationEvidence();
    final before = snapshot;
    ingress.reset(epoch);
    _notify(before, snapshot);
  }

  void append({
    required SourceEpoch epoch,
    required int offset,
    required List<int> bytes,
  }) {
    _observeWebpAnimationEvidence(bytes);
    final before = snapshot;
    ingress.append(epoch: epoch, offset: offset, bytes: bytes);
    _notify(before, snapshot);
  }

  void seal(SourceEpoch epoch) {
    final before = snapshot;
    ingress.seal(epoch);
    _notify(before, snapshot);
  }

  Future<void> rebuild({
    required SourceEpoch epoch,
    required Stream<List<int>> chunks,
    required bool sealed,
    TaskControl? control,
  }) async {
    _resetWebpAnimationEvidence();
    final before = snapshot;
    await ingress.rebuild(
      epoch: epoch,
      chunks: chunks.map((chunk) {
        _observeWebpAnimationEvidence(chunk);
        return chunk;
      }),
      sealed: sealed,
      control: control,
    );
    _notify(before, snapshot);
  }

  Future<bool> rebuildFromDirectFile({
    required SourceEpoch epoch,
    required List<int> metadataPrefix,
    required String path,
    required int endExclusive,
    required bool sealed,
    TaskControl? control,
  }) async {
    _resetWebpAnimationEvidence();
    _observeWebpAnimationEvidence(metadataPrefix);
    final before = snapshot;
    final rebuilt = await ingress.rebuildFromDirectFile(
      epoch: epoch,
      metadataPrefix: metadataPrefix,
      path: path,
      endExclusive: endExclusive,
      sealed: sealed,
      control: control,
    );
    _notify(before, snapshot);
    return rebuilt;
  }

  void fail(Failure failure) {
    final before = _synchronizedReplayBaseline ?? snapshot;
    ingress.fail(failure);
    _synchronizedReplayPending = false;
    _synchronizedReplayBaseline = null;
    _notify(before, snapshot);
  }

  void detach() {
    _synchronizedReplayBaseline = null;
    _listeners.clear();
  }

  void _observeWebpAnimationEvidence(List<int> bytes) {
    if (_webpAnimationEvidence != null || bytes.isEmpty) return;
    const prefixLimit = 64;
    final remaining = prefixLimit - _webpEvidencePrefix.length;
    if (remaining <= 0) return;
    _webpEvidencePrefix.addAll(bytes.take(remaining));
    _webpAnimationEvidence = parseWebpPrefixAnimationEvidence(
      Uint8List.fromList(_webpEvidencePrefix),
    );
    if (_webpAnimationEvidence != null) {
      _webpEvidencePrefix.clear();
    }
  }

  void _resetWebpAnimationEvidence() {
    _webpAnimationEvidence = null;
    _webpEvidencePrefix.clear();
  }

  void _notify(IngressSnap before, IngressSnap after) {
    // Synchronized replay is a private construction transaction. Its ingress
    // length/revision may advance before the encoded source is authoritative
    // for this Reader, so publishing those intermediate revisions would let a
    // source watcher consume the wake edge while [source] is still hidden.
    // The eventual publishSynchronizedReplayPrefix() call emits the single
    // consumer-visible source-ready transition.
    if (_synchronizedReplayPending && after.failure == null) return;
    final changed =
        before.revision != after.revision ||
        before.length != after.length ||
        before.sealed != after.sealed ||
        before.kind != after.kind ||
        before.sourceReady != after.sourceReady ||
        before.failure != after.failure;
    if (!changed) return;
    for (final listener in List<SourceListener>.of(_listeners)) {
      try {
        listener(after);
      } on Object {
        // Consumer observers must not break the native ingress projection.
      }
    }
  }
}
