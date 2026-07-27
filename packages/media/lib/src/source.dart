enum SourceStatus {
  ok,
  nullPointer,
  staleEpoch,
  invalidOffset,
  sealed,
  budget,
}

enum SourceKind { unknown, webp, gif, other }

abstract interface class EncodedSource {
  int get epoch;
  int get length;
  bool get sealed;
  SourceKind get kind;

  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  });

  SourceStatus seal(int epoch);
  SourceStatus reset(int epoch);
  void dispose();
}

abstract interface class SourceFactory {
  EncodedSource create({required int epoch, required int maxBytes});
}
