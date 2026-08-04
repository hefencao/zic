import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';

import 'decode_registry.dart';
import 'upload_registry.dart';

final class FrameBudget {
  const FrameBudget({
    required this.decodedBytes,
    required this.outputBytes,
    required this.currentDecodedReserve,
    required this.currentOutputReserve,
  });

  final int decodedBytes;
  final int outputBytes;
  final int currentDecodedReserve;
  final int currentOutputReserve;

  void validate() {
    if (decodedBytes < 0 || outputBytes < 0) {
      throw ArgumentError('frame byte budgets must not be negative');
    }
    if (currentDecodedReserve < 0 ||
        currentDecodedReserve > decodedBytes) {
      throw ArgumentError.value(
        currentDecodedReserve,
        'currentDecodedReserve',
        'must be within the decoded byte budget',
      );
    }
    if (currentOutputReserve < 0 || currentOutputReserve > outputBytes) {
      throw ArgumentError.value(
        currentOutputReserve,
        'currentOutputReserve',
        'must be within the output byte budget',
      );
    }
  }
}

final class FrameBudgetReport {
  const FrameBudgetReport({
    required this.decodedBefore,
    required this.decodedAfter,
    required this.outputBefore,
    required this.outputAfter,
    required this.currentDecoded,
    required this.currentOutput,
  });

  final int decodedBefore;
  final int decodedAfter;
  final int outputBefore;
  final int outputAfter;
  final int currentDecoded;
  final int currentOutput;

  int get decodedFreed => decodedBefore - decodedAfter;
  int get outputFreed => outputBefore - outputAfter;
}

/// Enforces frame budgets without sacrificing visible page outputs.
///
/// Current decoded bytes are protected. Current, transition and frozen-last
/// outputs are protected; other resources use only
/// the non-reserved portion
/// and are trimmed in ascending priority. If protected output alone exceeds
/// the total budget, the report stays over budget rather than turning a
/// visible page black.
final class FrameBudgeter {
  FrameBudgeter({
    required this.decodes,
    required this.uploads,
    required this.limits,
  }) {
    limits.validate();
  }

  final DecodeRegistry decodes;
  final UploadRegistry uploads;
  final FrameBudget limits;

  FrameBudgetReport enforce({
    required Map<DecodeId, DecodeDemand> decodeDemands,
    required Map<DecodeId, UploadDemand> uploadDemands,
  }) {
    final decodedBefore = decodes.totalBytes;
    final outputBefore = uploads.totalBytes;

    _trimDecoded(decodeDemands);
    _trimOutputs(uploadDemands);

    final currentDecodeIds = decodeDemands.entries
        .where((entry) => entry.value.role == PageRole.current)
        .map((entry) => entry.key)
        .toSet();
    final currentUploadIds = uploadDemands.entries
        .where((entry) => _protectsOutput(entry.value.role))
        .map((entry) => entry.key)
        .toSet();

    return FrameBudgetReport(
      decodedBefore: decodedBefore,
      decodedAfter: decodes.totalBytes,
      outputBefore: outputBefore,
      outputAfter: uploads.totalBytes,
      currentDecoded: decodes.bytesFor(currentDecodeIds),
      currentOutput: uploads.bytesFor(currentUploadIds),
    );
  }

  void _trimDecoded(Map<DecodeId, DecodeDemand> demands) {
    final current = demands.entries
        .where((entry) => entry.value.role == PageRole.current)
        .map((entry) => entry.key)
        .toSet();
    final currentBytes = decodes.bytesFor(current);
    final nonCurrentLimit = _remainingBudget(
      total: limits.decodedBytes,
      reserve: limits.currentDecodedReserve,
      current: currentBytes,
    );
    var nonCurrentBytes = decodes.totalBytes - currentBytes;
    final candidates = decodes.sessions
        .where((session) => !current.contains(session.id))
        .toList()
      ..sort((a, b) {
        final aPriority = demands[a.id]?.priority ?? -1;
        final bPriority = demands[b.id]?.priority ?? -1;
        return aPriority.compareTo(bPriority);
      });

    for (final session in candidates) {
      if (nonCurrentBytes <= nonCurrentLimit) {
        break;
      }
      final before = session.bytes;
      final overflow = nonCurrentBytes - nonCurrentLimit;
      session.trimBytes(before > overflow ? before - overflow : 0);
      nonCurrentBytes -= before - session.bytes;
    }
  }

  void _trimOutputs(Map<DecodeId, UploadDemand> demands) {
    final current = demands.entries
        .where((entry) => _protectsOutput(entry.value.role))
        .map((entry) => entry.key)
        .toSet();
    final currentBytes = uploads.bytesFor(current);
    final nonCurrentLimit = _remainingBudget(
      total: limits.outputBytes,
      reserve: limits.currentOutputReserve,
      current: currentBytes,
    );
    var nonCurrentBytes = uploads.totalBytes - currentBytes;
    final candidates = uploads.sessions
        .where((session) => !current.contains(session.id))
        .toList()
      ..sort((a, b) {
        final aPriority = demands[a.id]?.priority ?? -1;
        final bPriority = demands[b.id]?.priority ?? -1;
        return aPriority.compareTo(bPriority);
      });

    for (final session in candidates) {
      if (nonCurrentBytes <= nonCurrentLimit) {
        break;
      }
      final before = session.outputBytes;
      session.trimOutput();
      nonCurrentBytes -= before - session.outputBytes;
    }
  }

  int _remainingBudget({
    required int total,
    required int reserve,
    required int current,
  }) {
    final protected = current > reserve ? current : reserve;
    final remaining = total - protected;
    return remaining > 0 ? remaining : 0;
  }
}


bool _protectsOutput(PageRole role) =>
    role == PageRole.current ||
    role == PageRole.transition ||
    role == PageRole.last;
