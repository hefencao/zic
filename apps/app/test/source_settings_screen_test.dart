import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/source_settings_screen.dart';

void main() {
  testWidgets('source settings own adaptive trust and download policy', (
    tester,
  ) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    await preferences.attach(
      read: () async => <String, Object?>{
        'trustConflictingHistoricalCarriersByDefault': true,
        'sourceTrustConflictingHistoricalCarriers': <String, Object?>{
          'fixture:source': true,
        },
        'sourceDownloadDirectories': <String, Object?>{
          'fixture:source': '/data/fixture',
        },
        'sourceAdaptiveWebtoonConfidences': <String, Object?>{
          'fixture:source': 0.2,
        },
      },
      write: (_) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SourceSettingsScreen(
          sourceId: 'fixture:source',
          sourceName: 'Fixture',
          preferences: preferences,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(sourceSettingsScreenKey), findsOneWidget);
    expect(find.text('源设置 · Fixture'), findsOneWidget);
    expect(find.text('偏页漫 · 条漫置信 20%'), findsOneWidget);
    expect(find.text('/data/fixture'), findsOneWidget);

    await tester.tap(find.byKey(sourceSettingsDataTrustKey));
    await tester.pumpAndSettle();
    expect(find.text('数据信任'), findsWidgets);
    await tester.tap(find.text('严格校验'));
    await tester.pumpAndSettle();

    expect(
      preferences.conflictingHistoricalCarrierTrustOverrideForSource(
        'fixture:source',
      ),
      isFalse,
    );
    expect(find.text('严格校验'), findsOneWidget);
  });
}
