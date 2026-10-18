import 'package:flutter/material.dart';

import 'app_preferences.dart';

final class HomeHistoryLayoutSheet extends StatelessWidget {
  const HomeHistoryLayoutSheet({required this.preferences, super.key});

  final AppPreferencesController preferences;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: ListenableBuilder(
        listenable: preferences,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('阅读历史布局', style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: '关闭布局设置', icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final entry in const {
                HomeHistoryLayout.grid: ('网格', Icons.grid_view),
                HomeHistoryLayout.carousel: ('横向书架', Icons.view_week_outlined),
                HomeHistoryLayout.list: ('列表', Icons.view_list_outlined),
              }.entries)
                ChoiceChip(
                  key: ValueKey('home-history-layout-${entry.key.name}'),
                  avatar: Icon(entry.value.$2, size: 18),
                  label: Text(entry.value.$1),
                  selected: preferences.homeHistoryLayout == entry.key,
                  showCheckmark: false,
                  onSelected: (_) => preferences.setHomeHistoryLayout(entry.key),
                ),
            ]),
            const SizedBox(height: 16),
            Text(switch (preferences.homeHistoryLayout) {
              HomeHistoryLayout.grid => '多行封面，随首页上下滚动。',
              HomeHistoryLayout.carousel => '固定行数，左右滑动浏览。',
              HomeHistoryLayout.list => '每本一行，显示章节和阅读位置。',
            }),
            if (preferences.homeHistoryLayout != HomeHistoryLayout.list) ...[
              const SizedBox(height: 20),
              Text(preferences.homeHistoryLayout == HomeHistoryLayout.grid ? '每行数量' : '显示行数',
                style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              if (preferences.homeHistoryLayout == HomeHistoryLayout.grid) ...[
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (var count = 2; count <= 6; count++)
                    ChoiceChip(label: Text('$count 列'), showCheckmark: false,
                      selected: preferences.homeHistoryColumns == count,
                      onSelected: (_) => preferences.setHomeHistoryColumns(count)),
                ]),
                const SizedBox(height: 8),
                const Text('屏幕较窄时会自动减少列数，保证封面可读。'),
              ] else
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (var count = 1; count <= 3; count++)
                    ChoiceChip(label: Text('$count 行'), showCheckmark: false,
                      selected: preferences.homeHistoryRows == count,
                      onSelected: (_) => preferences.setHomeHistoryRows(count)),
                ]),
            ],
          ],
        ),
      ),
    ),
  );
}
