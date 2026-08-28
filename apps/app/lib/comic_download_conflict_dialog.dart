import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';

import 'dialog_actions.dart';

enum ComicConflictDecision {
  overwrite,
  saveAsNew,
  cancel,
}

/// Prompt conflict resolution according to candidate confidence:
/// 1. No candidates with existing files -> direct download (returns overwrite).
/// 2. Single candidate -> direct comparison dialog.
/// 3. Multiple candidates -> confidence selection dialog, then comparison dialog.
Future<ComicConflictDecision> promptComicConflictResolution({
  required BuildContext context,
  required ComicConflictReport report,
  required String comicTitle,
  required String sourceId,
  String? sourceDisplayName,
  String? chapterTitle,
}) async {
  final activeCandidates = List<ComicFolderCandidate>.from(report.candidates)
    ..sort((a, b) => b.confidenceScore.compareTo(a.confidenceScore));

  if (activeCandidates.isEmpty) {
    return ComicConflictDecision.overwrite;
  }

  if (activeCandidates.length == 1) {
    return await showComicConflictCompareDialog(
      context: context,
      candidate: activeCandidates.first,
      recommendedDirectoryName: report.recommendedDirectoryName,
      comicTitle: comicTitle,
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      chapterTitle: chapterTitle,
    );
  }

  final selected = await showComicConflictCandidateListDialog(
    context: context,
    candidates: activeCandidates,
    comicTitle: comicTitle,
    sourceDisplayName: sourceDisplayName ?? sourceId,
    recommendedDirectoryName: report.recommendedDirectoryName,
  );

  if (selected == null) {
    return ComicConflictDecision.cancel;
  }

  if (selected.saveAsNew) {
    return ComicConflictDecision.saveAsNew;
  }

  final candidate = selected.candidate;
  if (candidate == null) {
    return ComicConflictDecision.cancel;
  }

  return await showComicConflictCompareDialog(
    context: context,
    candidate: candidate,
    recommendedDirectoryName: report.recommendedDirectoryName,
    comicTitle: comicTitle,
    sourceId: sourceId,
    sourceDisplayName: sourceDisplayName,
    chapterTitle: chapterTitle,
  );
}

final class _CandidateSelectionResult {
  const _CandidateSelectionResult({
    this.candidate,
    this.saveAsNew = false,
  });

  final ComicFolderCandidate? candidate;
  final bool saveAsNew;
}

Future<_CandidateSelectionResult?> showComicConflictCandidateListDialog({
  required BuildContext context,
  required List<ComicFolderCandidate> candidates,
  required String comicTitle,
  required String sourceDisplayName,
  required String recommendedDirectoryName,
}) async {
  return showDialog<_CandidateSelectionResult>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      return AlertDialog(
        title: const Text('发现多个相似下载目录'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '本地存在多个同名或相似目录，请选择要核对/覆盖的目标目录：',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final candidate = candidates[index];
                    final scorePercent = (candidate.confidenceScore * 100).toInt();
                    final badgeColor = candidate.confidenceScore >= 0.95
                        ? colorScheme.primaryContainer
                        : (candidate.confidenceScore >= 0.8
                            ? colorScheme.secondaryContainer
                            : colorScheme.surfaceContainerHighest);
                    final badgeTextColor = candidate.confidenceScore >= 0.95
                        ? colorScheme.onPrimaryContainer
                        : (candidate.confidenceScore >= 0.8
                            ? colorScheme.onSecondaryContainer
                            : colorScheme.onSurfaceVariant);

                    return Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      color: colorScheme.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).pop(
                          _CandidateSelectionResult(candidate: candidate),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      candidate.folderName,
                                      style: theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: badgeColor,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '$scorePercent% ${candidate.confidenceLabel}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: badgeTextColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${candidate.existingPageFilesCount} 个图片文件 · '
                                '${candidate.chapterCount > 0 ? '${candidate.chapterCount} 个章节' : '单章节图集'}'
                                ' · 来源: ${candidate.manifest?.sourceDisplayName ?? candidate.manifest?.sourceId ?? '未知'}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.of(context).pop(null),
            actions: <Widget>[
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(
                  const _CandidateSelectionResult(saveAsNew: true),
                ),
                child: const Text('另存为新目录'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

Future<ComicConflictDecision> showComicConflictCompareDialog({
  required BuildContext context,
  required ComicFolderCandidate candidate,
  required String recommendedDirectoryName,
  required String comicTitle,
  required String sourceId,
  String? sourceDisplayName,
  String? chapterTitle,
}) async {
  final decision = await showDialog<ComicConflictDecision>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      final scorePercent = (candidate.confidenceScore * 100).toInt();

      return AlertDialog(
        title: const Text('对比本地文件与待下载内容'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Local existing card
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.folder_outlined,
                              size: 18,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '本地已有目录',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$scorePercent% ${candidate.confidenceLabel}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 16),
                        _InfoRow(label: '目录名称', value: candidate.folderName),
                        _InfoRow(
                          label: '已有内容',
                          value:
                              '${candidate.existingPageFilesCount} 个图片文件 · ${candidate.chapterCount > 0 ? '${candidate.chapterCount} 个章节' : '单章节图集'}',
                        ),
                        _InfoRow(
                          label: '历史来源',
                          value: candidate.manifest?.sourceDisplayName ??
                              candidate.manifest?.sourceId ??
                              '未知',
                        ),
                      ],
                    ),
                  ),
                ),

                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: Icon(Icons.arrow_downward_rounded, size: 20),
                  ),
                ),

                // Incoming download card
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: colorScheme.primaryContainer.withValues(alpha: 0.25),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.download_for_offline_outlined,
                              size: 18,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '本次待下载内容',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 16),
                        _InfoRow(label: '漫画名称', value: comicTitle),
                        _InfoRow(
                          label: '当前来源',
                          value: sourceDisplayName ?? sourceId,
                        ),
                        _InfoRow(
                          label: '目标章节',
                          value: chapterTitle ?? '整本漫画',
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // Warning
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '直接覆盖将替换同名文件并更新目录元数据；若想保留已有文件，请选择「另存为新目录」。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () =>
                Navigator.of(context).pop(ComicConflictDecision.cancel),
            actions: <Widget>[
              OutlinedButton(
                onPressed: () =>
                    Navigator.of(context).pop(ComicConflictDecision.saveAsNew),
                child: const Text('另存为新目录'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(ComicConflictDecision.overwrite),
                child: const Text('覆盖并下载'),
              ),
            ],
          ),
        ],
      );
    },
  );

  return decision ?? ComicConflictDecision.cancel;
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
