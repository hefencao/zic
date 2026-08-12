/// Rank-only policy for physical transfer admission costs.
///
/// Pipeline owns the semantic demand priority. Sessions consumes that numeric
/// rank and compares it with physical transfer costs; it must not rediscover
/// Reader roles such as current/previous or hard-code role names.
final class TransferRankPolicy {
  const TransferRankPolicy({
    this.largePrefixBytes = 1024 * 1024,
    this.veryLargePrefixBytes = 8 * 1024 * 1024,
    this.largePrefixCatchupRank = 820,
    this.veryLargePrefixCatchupRank = 900,
    this.requiredCompletionRank = 1 << 30,
  })  : assert(largePrefixBytes >= 0),
        assert(veryLargePrefixBytes >= largePrefixBytes),
        assert(largePrefixCatchupRank >= 0),
        assert(veryLargePrefixCatchupRank >= largePrefixCatchupRank);

  final int largePrefixBytes;
  final int veryLargePrefixBytes;
  final int largePrefixCatchupRank;
  final int veryLargePrefixCatchupRank;
  final int requiredCompletionRank;

  int demandRank({
    required int priority,
    required bool completionRequired,
  }) =>
      completionRequired ? requiredCompletionRank : priority;

  int fullBodyCatchupCostRank(int preservedLength) {
    if (preservedLength < largePrefixBytes) return 0;
    if (preservedLength < veryLargePrefixBytes) return largePrefixCatchupRank;
    return veryLargePrefixCatchupRank;
  }

  bool allowsFullBodyCatchup({
    required int priority,
    required bool completionRequired,
    required int preservedLength,
  }) =>
      demandRank(
        priority: priority,
        completionRequired: completionRequired,
      ) >=
      fullBodyCatchupCostRank(preservedLength);
}
