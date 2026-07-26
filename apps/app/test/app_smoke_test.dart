import 'package:flutter_test/flutter_test.dart';
import 'package:zic/main.dart';

void main() {
  testWidgets('demo chapter opens', (tester) async {
    await tester.pumpWidget(const App());
    await tester.pumpAndSettle();

    expect(find.textContaining('zic ·'), findsOneWidget);
    expect(find.text('1 / 100'), findsOneWidget);
  });
}
