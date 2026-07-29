import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

const sourceMigrationComparisonDialogKey =
    ValueKey<String>('source-migration-comparison-dialog');
const sourceMigrationComparisonConfirmKey =
    ValueKey<String>('source-migration-comparison-confirm');
const sourceMigrationComparisonAcknowledgeKey =
    ValueKey<String>('source-migration-comparison-acknowledge');
const sourceMigrationComparisonSourceKey =
    ValueKey<String>('source-migration-comparison-source');
const sourceMigrationComparisonTargetKey =
    ValueKey<String>('source-migration-comparison-target');
const sourceMigrationComparisonRisksKey =
    ValueKey<String>('source-migration-comparison-risks');
const sourceMigrationComparisonChaptersKey =
    ValueKey<String>('source-migration-comparison-chapters');

typedef SourceMigrationCoverLoader = Future<Uint8List> Function();

Future<bool> showSourceMigrationComparison({
  required BuildContext context,
  required ComicSourceMigrationPlan plan,
  required String sourceName,
  required String targetName,
  SourceMigrationCoverLoader? loadSourceCover,
  SourceMigrationCoverLoader? loadTargetCover,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _SourceMigrationComparisonDialog(
      plan: plan,
      sourceName: sourceName,
      targetName: targetName,
      loadSourceCover: loadSourceCover,
      loadTargetCover: loadTargetCover,
    ),
  );
  return result ?? false;
}

final class _SourceMigrationComparisonDialog extends StatefulWidget {
  const _SourceMigrationComparisonDialog({
    required this.plan,
    required this.sourceName,
    required this.targetName,
    required this.loadSourceCover,
    required this.loadTargetCover,
  });

  final ComicSourceMigrationPlan plan;
  final String sourceName;
  final String targetName;
  final SourceMigrationCoverLoader? loadSourceCover;
  final SourceMigrationCoverLoader? loadTargetCover;

  @override
  State<_SourceMigrationComparisonDialog> createState() =>
      _SourceMigrationComparisonDialogState();
}

final class _SourceMigrationComparisonDialogState
    extends State<_SourceMigrationComparisonDialog> {
  var _acknowledgedIdentity = false;

  @override
  Widget build(BuildContext context) {
    final comparison = widget.plan.comparison();
    final media = MediaQuery.sizeOf(context);
    final dialogWidth = (media.width - 48).clamp(272.0, 872.0).toDouble();
    final dialogHeight =
        (media.height - 180).clamp(260.0, 620.0).toDouble();
    return AlertDialog(
      key: sourceMigrationComparisonDialogKey,
      insetPadding: const EdgeInsets.all(24),
      title: const Text('核对漫画源迁移'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = <Widget>[
                    _MigrationComicCard(
                      key: sourceMigrationComparisonSourceKey,
                      label: '当前来源',
                      sourceName: widget.sourceName,
                      identity: comparison.sourceIdentity,
                      title: comparison.sourceTitle,
                      authors: comparison.sourceAuthors,
                      chapterSummary:
                          '已保存 ${widget.plan.source.chapters.length} 章',
                      readingDirection: _readingDirectionLabel(
                        widget.plan.source.readingDirection.name,
                      ),
                      loadCover: widget.loadSourceCover,
                    ),
                    _MigrationComicCard(
                      key: sourceMigrationComparisonTargetKey,
                      label: '目标来源',
                      sourceName: widget.targetName,
                      identity: comparison.targetIdentity,
                      title: comparison.targetTitle,
                      authors: comparison.targetAuthors,
                      chapterSummary:
                          '目标目录 ${widget.plan.target.chapters.length} 章',
                      readingDirection: _readingDirectionLabel(
                        widget.plan.target.comic.readingDirection.name,
                      ),
                      loadCover: widget.loadTargetCover,
                    ),
                  ];
                  if (constraints.maxWidth < 620) {
                    return Column(
                      children: <Widget>[
                        cards.first,
                        const SizedBox(height: 12),
                        cards.last,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: cards.first),
                      const SizedBox(width: 12),
                      Expanded(child: cards.last),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              _MigrationEvidence(comparison: comparison),
              const SizedBox(height: 12),
              _MigrationRisks(comparison: comparison),
              const SizedBox(height: 12),
              _MigrationChapterSamples(comparison: comparison),
              const SizedBox(height: 12),
              const Text(
                '迁移只复制漫画偏好和经过验证的阅读状态。目标源已有状态优先保留；'
                '来源专属 URL、离线字节和原来源漫画都不会被删除或替换。',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: sourceMigrationComparisonAcknowledgeKey,
                contentPadding: EdgeInsets.zero,
                value: _acknowledgedIdentity,
                onChanged: (value) => setState(
                  () => _acknowledgedIdentity = value ?? false,
                ),
                title: const Text('我已核对目标来源、原生 ID 和章节匹配风险'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: sourceMigrationComparisonConfirmKey,
          onPressed: _acknowledgedIdentity
              ? () => Navigator.pop(context, true)
              : null,
          child: const Text('确认复制到目标源'),
        ),
      ],
    );
  }
}

final class _MigrationComicCard extends StatelessWidget {
  const _MigrationComicCard({
    required super.key,
    required this.label,
    required this.sourceName,
    required this.identity,
    required this.title,
    required this.authors,
    required this.chapterSummary,
    required this.readingDirection,
    required this.loadCover,
  });

  final String label;
  final String sourceName;
  final String identity;
  final String title;
  final List<String> authors;
  final String chapterSummary;
  final String readingDirection;
  final SourceMigrationCoverLoader? loadCover;

  @override
  Widget build(BuildContext context) {
    return _outlinedCard(
      context,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _MigrationCover(loadCover: loadCover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(authors.isEmpty ? '作者未提供' : authors.join('、')),
                  const SizedBox(height: 6),
                  Text('$sourceName · $chapterSummary · $readingDirection'),
                  const SizedBox(height: 6),
                  SelectableText(
                    identity,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MigrationCover extends StatefulWidget {
  const _MigrationCover({required this.loadCover});

  final SourceMigrationCoverLoader? loadCover;

  @override
  State<_MigrationCover> createState() => _MigrationCoverState();
}

final class _MigrationCoverState extends State<_MigrationCover> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loadCover?.call();
  }

  @override
  void didUpdateWidget(covariant _MigrationCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.loadCover, widget.loadCover)) {
      _future = widget.loadCover?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) {
      return const _MissingMigrationCover();
    }
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return const _MissingMigrationCover();
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 82,
            height: 116,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const _MissingMigrationCover(),
          ),
        );
      },
    );
  }
}

final class _MissingMigrationCover extends StatelessWidget {
  const _MissingMigrationCover();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 82,
      height: 116,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: const Icon(Icons.image_not_supported_outlined),
    );
  }
}

final class _MigrationEvidence extends StatelessWidget {
  const _MigrationEvidence({required this.comparison});

  final ComicSourceMigrationComparison comparison;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _EvidenceChip(
        label: comparison.titleMatches ? '标题一致' : '标题不同',
        positive: comparison.titleMatches,
      ),
      _EvidenceChip(
        label: comparison.sharedAuthors.isEmpty
            ? '无共同作者'
            : '共同作者 ${comparison.sharedAuthors.join('、')}',
        positive: comparison.sharedAuthors.isNotEmpty,
      ),
      _EvidenceChip(
        label: '精确章节 ${comparison.exactChapterMatches}',
        positive: comparison.exactChapterMatches > 0,
      ),
      _EvidenceChip(
        label: '仅序号 ${comparison.sequenceOnlyChapterMatches}',
        positive: comparison.sequenceOnlyChapterMatches == 0,
      ),
      _EvidenceChip(
        label: '源未匹配 ${comparison.unmatchedSourceChapters}',
        positive: comparison.unmatchedSourceChapters == 0,
      ),
      _EvidenceChip(
        label: '目标额外章节 ${comparison.unmatchedTargetChapters}',
        positive: true,
      ),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }
}

final class _EvidenceChip extends StatelessWidget {
  const _EvidenceChip({required this.label, required this.positive});

  final String label;
  final bool positive;

  @override
  Widget build(BuildContext context) => Chip(
        avatar: Icon(
          positive ? Icons.check_circle_outline : Icons.info_outline,
          size: 18,
        ),
        label: Text(label),
      );
}

final class _MigrationRisks extends StatelessWidget {
  const _MigrationRisks({required this.comparison});

  final ComicSourceMigrationComparison comparison;

  @override
  Widget build(BuildContext context) {
    if (!comparison.hasRisks) {
      return _outlinedCard(
        context,
        key: sourceMigrationComparisonRisksKey,
        child: const ListTile(
          leading: Icon(Icons.verified_outlined),
          title: Text('未发现额外身份风险'),
          subtitle: Text('仍会使用目标源章节详情进行逐章身份验证。'),
        ),
      );
    }
    return _outlinedCard(
      context,
      key: sourceMigrationComparisonRisksKey,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('需要核对', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final risk in comparison.risks)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.warning_amber_rounded, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_riskLabel(risk))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _MigrationChapterSamples extends StatelessWidget {
  const _MigrationChapterSamples({required this.comparison});

  final ComicSourceMigrationComparison comparison;

  @override
  Widget build(BuildContext context) {
    final samples = comparison.chapterSamples;
    return _outlinedCard(
      context,
      key: sourceMigrationComparisonChaptersKey,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('章节样本', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (samples.isEmpty)
              const Text('当前没有已保存章节可用于状态匹配。')
            else
              for (final sample in samples)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '#${sample.sourceSequence} ${sample.sourceTitle}',
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, size: 18),
                      ),
                      Expanded(
                        child: Text(
                          sample.matched
                              ? '#${sample.targetSequence} ${sample.targetTitle}'
                              : '未匹配',
                          style: sample.matched
                              ? null
                              : TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                        ),
                      ),
                      SizedBox(
                        width: 62,
                        child: Text(
                          switch (sample.confidence) {
                            ChapterMigrationConfidence.exact => '精确',
                            ChapterMigrationConfidence.sequenceOnly => '仅序号',
                            null => '',
                          },
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

String _riskLabel(ComicSourceMigrationRisk risk) => switch (risk) {
      ComicSourceMigrationRisk.titleDiffers => '当前标题与目标标题不同。',
      ComicSourceMigrationRisk.noSharedAuthors => '双方都提供作者，但没有共同作者。',
      ComicSourceMigrationRisk.readingDirectionDiffers => '阅读方向不同，迁移后以目标源设置为准。',
      ComicSourceMigrationRisk.sequenceOnlyMatches =>
        '存在只按章节序号匹配的候选；这些章节不会迁移阅读状态。',
      ComicSourceMigrationRisk.unmatchedSourceChapters =>
        '部分已保存章节在目标目录中没有匹配项。',
      ComicSourceMigrationRisk.targetCatalogEmpty => '目标源没有提供章节目录。',
    };

Widget _outlinedCard(
  BuildContext context, {
  Key? key,
  required Widget child,
}) =>
    Card(
      key: key,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: child,
    );

String _readingDirectionLabel(String value) => switch (value) {
      'ltr' => '从左到右',
      'rtl' => '从右到左',
      'vertical' => '纵向',
      _ => value,
    };
