import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';

import 'dialog_actions.dart';

enum ComicConflictDecision {
  overwrite,
  saveAsNew,
  cancel,
}

/// The result of a conflict resolution prompt including the decision and the
/// target directory name chosen by the user.
final class ComicConflictResolutionResult {
  const ComicConflictResolutionResult({
    required this.decision,
    this.targetDirectoryName,
  });

  final ComicConflictDecision decision;
  final String? targetDirectoryName;
}

/// Prompt conflict resolution according to candidate confidence:
/// 1. No candidates with existing files -> direct download (returns overwrite).
/// 2. Single candidate -> direct comparison dialog.
/// 3. Multiple candidates -> confidence selection dialog, then comparison dialog.
Future<ComicConflictResolutionResult> promptComicConflictResolutionResult({
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
    return ComicConflictResolutionResult(
      decision: ComicConflictDecision.overwrite,
      targetDirectoryName: report.recommendedDirectoryName,
    );
  }

  if (activeCandidates.length == 1) {
    final candidate = activeCandidates.first;
    final decision = await showComicConflictCompareDialog(
      context: context,
      candidate: candidate,
      recommendedDirectoryName: report.recommendedDirectoryName,
      comicTitle: comicTitle,
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      chapterTitle: chapterTitle,
    );
    return ComicConflictResolutionResult(
      decision: decision,
      targetDirectoryName: decision == ComicConflictDecision.saveAsNew
          ? _uniqueSaveAsNewDirectoryName(report)
          : (decision == ComicConflictDecision.overwrite
              ? candidate.folderName
              : null),
    );
  }

  final selected = await showComicConflictCandidateListDialog(
    context: context,
    candidates: activeCandidates,
    comicTitle: comicTitle,
    sourceDisplayName: sourceDisplayName ?? sourceId,
    recommendedDirectoryName: report.recommendedDirectoryName,
  );

  if (!context.mounted) {
    return const ComicConflictResolutionResult(
      decision: ComicConflictDecision.cancel,
    );
  }

  if (selected == null) {
    return const ComicConflictResolutionResult(
      decision: ComicConflictDecision.cancel,
    );
  }

  if (selected.saveAsNew) {
    return ComicConflictResolutionResult(
      decision: ComicConflictDecision.saveAsNew,
      targetDirectoryName: _uniqueSaveAsNewDirectoryName(report),
    );
  }

  final candidate = selected.candidate;
  if (candidate == null) {
    return const ComicConflictResolutionResult(
      decision: ComicConflictDecision.cancel,
    );
  }

  final decision = await showComicConflictCompareDialog(
    context: context,
    candidate: candidate,
    recommendedDirectoryName: report.recommendedDirectoryName,
    comicTitle: comicTitle,
    sourceId: sourceId,
    sourceDisplayName: sourceDisplayName,
    chapterTitle: chapterTitle,
  );
  return ComicConflictResolutionResult(
    decision: decision,
    targetDirectoryName: decision == ComicConflictDecision.saveAsNew
        ? _uniqueSaveAsNewDirectoryName(report)
        : (decision == ComicConflictDecision.overwrite
            ? candidate.folderName
            : null),
  );
}

String _uniqueSaveAsNewDirectoryName(ComicConflictReport report) {
  final occupied = report.occupiedDirectoryNames;
  var candidate = report.recommendedDirectoryName;
  if (!occupied.contains(candidate)) return candidate;
  final base = candidate;
  var sequence = 2;
  do {
    candidate = '$base (copy $sequence)';
    sequence++;
  } while (occupied.contains(candidate));
  return candidate;
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
                child: const Text('新建独立任务'),
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
      final isIncomingNewer =
          candidate.versionRelation == ComicVersionRelationKind.incomingIsNewer;
      final isExistingNewer =
          candidate.versionRelation == ComicVersionRelationKind.existingIsNewer;

      final Color bannerBgColor;
      final Color bannerBorderColor;
      final IconData statusIcon;
      final Color statusColor;
      final String statusTitle;
      final String statusDesc;
      final String statusNote;

      if (isIncomingNewer) {
        bannerBgColor = colorScheme.primaryContainer.withValues(alpha: 0.35);
        bannerBorderColor = colorScheme.primary.withValues(alpha: 0.4);
        statusIcon = Icons.update_rounded;
        statusColor = colorScheme.primary;
        statusTitle = '发现新版本更新';
        statusDesc =
            '本次下载为更新版本，本地已有历史版本（${candidate.existingPageFilesCount} 个图片文件'
            '${candidate.chapterCount > 0 ? ' · ${candidate.chapterCount} 个章节' : ''}）。';
        statusNote = '默认推荐：新任务替换旧任务（复用已有相同文件，仅下载差异页面，旧任务将被新任务替换）。';
      } else if (isExistingNewer) {
        bannerBgColor = colorScheme.errorContainer.withValues(alpha: 0.35);
        bannerBorderColor = colorScheme.error.withValues(alpha: 0.4);
        statusIcon = Icons.warning_amber_rounded;
        statusColor = colorScheme.error;
        statusTitle = '本地已存在更新版本';
        statusDesc =
            '本地已下载较新版本（${candidate.existingPageFilesCount} 个图片文件），当前发起的为历史旧版本。';
        statusNote = '默认推荐：保持现有版本（什么都不做），避免旧版本误覆盖已下载的新版本。';
      } else if (candidate.isExactMatch) {
        bannerBgColor = colorScheme.surfaceContainerLow;
        bannerBorderColor = colorScheme.outlineVariant.withValues(alpha: 0.5);
        statusIcon = Icons.check_circle_outline_rounded;
        statusColor = colorScheme.primary;
        statusTitle = '检测到同名已下载内容';
        statusDesc =
            '本地已有完全匹配的目录与文件（${candidate.existingPageFilesCount} 个图片文件）。';
        statusNote = '默认推荐：新任务替换旧任务（增量断点续传/复用已有文件）。';
      } else {
        bannerBgColor = colorScheme.surfaceContainerLow;
        bannerBorderColor = colorScheme.outlineVariant.withValues(alpha: 0.5);
        statusIcon = Icons.folder_open_rounded;
        statusColor = colorScheme.secondary;
        statusTitle = candidate.isTitleMatch
            ? '检测到同名下载目录'
            : '检测到已占用下载目录';
        statusDesc = candidate.isTitleMatch
            ? '本地目录「${candidate.folderName}」中已有 ${candidate.existingPageFilesCount} 个文件。'
            : '目标目录「${candidate.folderName}」已有其他下载所有者，不能直接接管。';
        statusNote = '选择「新任务替换旧任务」将按已确认所有者尝试替换；选择下方「新建任务」将独立保存。';
      }

      return AlertDialog(
        title: const Text('下载任务处理'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Task handling status banner
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: bannerBgColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: bannerBorderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(statusIcon, size: 20, color: statusColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              statusTitle,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: statusColor,
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
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              candidate.confidenceLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        statusDesc,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        statusNote,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Bottom expandable section: Create new task (expand for details comparison)
                Theme(
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                    childrenPadding: const EdgeInsets.only(top: 8, bottom: 4),
                    leading: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      '新建任务（可展开对比）',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '将新旧版本分别保存在独立目录中',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
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
                                  Text(
                                    '$scorePercent% 匹配度',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
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

                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                          label: const Text('另存为新目录并新建任务'),
                          onPressed: () => Navigator.of(context).pop(
                            ComicConflictDecision.saveAsNew,
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
              if (isExistingNewer) ...<Widget>[
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pop(ComicConflictDecision.overwrite),
                  child: const Text('仍要替换为旧版本'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(ComicConflictDecision.cancel),
                  child: const Text('保持现有版本（什么都不做）'),
                ),
              ] else ...<Widget>[
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pop(ComicConflictDecision.cancel),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(ComicConflictDecision.overwrite),
                  child: const Text('新任务替换旧任务'),
                ),
              ],
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
